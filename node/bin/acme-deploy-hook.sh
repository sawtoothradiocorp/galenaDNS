#!/usr/bin/env bash
#
# galena-dns — certbot deploy hook.
#
# Runs after a successful issuance or renewal. Two jobs:
#
#   1. Copy the certificate somewhere the unprivileged _dnsdist user can read it.
#      /etc/letsencrypt/live and /archive are root-only by design, so dnsdist
#      cannot be pointed at them directly.
#
#   2. Tell dnsdist to pick up the new files. dnsdist does NOT watch certificate
#      files on disk — without this step it keeps serving the old certificate
#      until the process restarts, which means it will happily serve an EXPIRED
#      certificate a month after a successful renewal. This is the single most
#      important line in this repo for not waking up to an outage.
#
# Invoked by certbot with RENEWED_LINEAGE set. Safe to run by hand.

set -euo pipefail

TLS_DIR=/etc/dnsdist/tls

log() { printf '[acme-deploy] %s\n' "$*"; }
die() {
  printf '[acme-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

lineage="${RENEWED_LINEAGE:-}"
if [[ -z $lineage ]]; then
  # Manual invocation: fall back to the configured domain.
  # shellcheck source=/dev/null
  [[ -r /opt/galena/node.env ]] && source /opt/galena/node.env
  [[ -n ${GALENA_DOMAIN:-} ]] || die "RENEWED_LINEAGE unset and GALENA_DOMAIN unknown"
  lineage="/etc/letsencrypt/live/${GALENA_DOMAIN}"
  log "RENEWED_LINEAGE unset; using ${lineage}"
fi

[[ -r "${lineage}/fullchain.pem" ]] || die "no fullchain.pem in ${lineage}"
[[ -r "${lineage}/privkey.pem" ]] || die "no privkey.pem in ${lineage}"

# Sanity-check before installing: a truncated or mismatched pair would take the
# listeners down on reload, and a failed reload is much harder to debug than a
# refusal here.
openssl x509 -in "${lineage}/fullchain.pem" -noout >/dev/null 2>&1 \
  || die "fullchain.pem is not a valid certificate"
# Compare public keys rather than RSA moduli: certbot here issues ECDSA, and
# `openssl rsa -modulus` silently does nothing useful for an EC key.
cert_pub=$(openssl x509 -in "${lineage}/fullchain.pem" -noout -pubkey 2>/dev/null) \
  || die "cannot read public key from fullchain.pem"
key_pub=$(openssl pkey -in "${lineage}/privkey.pem" -pubout 2>/dev/null) \
  || die "cannot read public key from privkey.pem"
[[ $cert_pub == "$key_pub" ]] || die "certificate and private key do not match"

getent group _dnsdist >/dev/null || die "the _dnsdist group is missing; is dnsdist installed?"
# The parent must be traversable by _dnsdist too, or the key below is unreachable
# no matter how its own permissions are set.
install -d -m 0750 -o root -g _dnsdist /etc/dnsdist
install -d -m 0750 -o root -g _dnsdist "$TLS_DIR"

# Write to a temporary name and rename, so a reload can never observe a
# half-written key.
umask 027
install -m 0640 -o root -g _dnsdist "${lineage}/fullchain.pem" "${TLS_DIR}/.fullchain.pem.new"
install -m 0640 -o root -g _dnsdist "${lineage}/privkey.pem" "${TLS_DIR}/.privkey.pem.new"
mv -f "${TLS_DIR}/.fullchain.pem.new" "${TLS_DIR}/fullchain.pem"
mv -f "${TLS_DIR}/.privkey.pem.new" "${TLS_DIR}/privkey.pem"

not_after=$(openssl x509 -in "${TLS_DIR}/fullchain.pem" -noout -enddate | cut -d= -f2)
log "installed certificate, expires ${not_after}"

if ! systemctl is-active --quiet dnsdist; then
  log "dnsdist not running; nothing to reload (bootstrap will start it)"
  exit 0
fi

# dnsdist client mode reads the console address and key out of dnsdist.conf.
out=$(dnsdist -c -e 'reloadAllCertificates()' 2>&1) || die "console reload failed: ${out}"
case $out in
  *[Ee]rror* | *rror*) die "console reported an error: ${out}" ;;
esac

log "dnsdist reloaded certificates"
