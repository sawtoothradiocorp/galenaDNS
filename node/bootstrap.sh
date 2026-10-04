#!/usr/bin/env bash
#
# galena-dns — node configuration.
#
# Idempotent: safe to re-run after every `make deploy`. Ordering is deliberate
# and is the part most likely to bite if changed:
#
#   unbound  ->  resolv.conf  ->  certbot  ->  dnsdist
#
# certbot needs working DNS, which comes from unbound; dnsdist needs the
# certificate that certbot produces. During cloud-init the host still uses
# Hetzner's resolvers, and this script only switches /etc/resolv.conf to
# 127.0.0.1 once unbound has actually answered a query.

set -euo pipefail

REPO=/opt/galena
RPZ_DIR=/var/lib/unbound/rpz
MANIFEST="${REPO}/rpz-manifest.tsv"

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else
  B=''; G=''; Y=''; R=''; N=''
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok() { printf '    %s+%s %s\n' "$G" "$N" "$*"; }
warn() { printf '    %s!%s %s\n' "$Y" "$N" "$*"; }
die() {
  printf '\n%sFAILED:%s %s\n' "$R" "$N" "$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "must run as root"

# envsubst silently writes an empty string for an unset variable, which produces
# configs that are wrong rather than rejected — `RuntimeMaxUse=` and
# `msg-cache-size:` with no value both got past a deploy that way. Every render
# below declares what it needs first.
require_vars() {
  local v missing=()
  for v in "$@"; do
    [[ -n ${!v:-} ]] || missing+=("$v")
  done
  ((${#missing[@]} == 0)) || die "these settings are empty, so the rendered config would be broken:
  ${missing[*]}
They come from ${REPO}/node.env. Check that 'make deploy' pushed it and that
bootstrap sources it with 'set -a' so envsubst can see them."
}

# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
step "Loading configuration"
[[ -r "${REPO}/node.env" ]] || die "${REPO}/node.env missing — was this node created by Terraform?"
# `set -a` matters: node.env assigns without `export`, and envsubst only
# substitutes variables that are in the ENVIRONMENT. Without this, every setting
# that comes from node.env renders as an empty string and the configs come out
# subtly broken rather than obviously broken.
set -a
# shellcheck source=/dev/null
source "${REPO}/node.env"
set +a

for v in GALENA_DOMAIN GALENA_ACME_EMAIL GALENA_RPZ_ZONES GALENA_ADMIN_CIDR; do
  [[ -n ${!v:-} ]] || die "${v} is not set in node.env"
done
[[ -r "$MANIFEST" ]] || die "${MANIFEST} missing"
ok "domain=${GALENA_DOMAIN} zones=${GALENA_RPZ_ZONES}"

. /etc/os-release
CODENAME="${VERSION_CODENAME:-trixie}"
ok "base=${PRETTY_NAME}"

# --------------------------------------------------------------------------
# Derived values the templates need
# --------------------------------------------------------------------------
step "Computing derived configuration"

GALENA_NUM_THREADS=$(nproc)
# unbound wants cache slabs as a power of two, at least the thread count.
slabs=1
while ((slabs < GALENA_NUM_THREADS)); do slabs=$((slabs * 2)); done
GALENA_CACHE_SLABS=$slabs
export GALENA_NUM_THREADS GALENA_CACHE_SLABS
ok "threads=${GALENA_NUM_THREADS} slabs=${GALENA_CACHE_SLABS}"

# Rate-limit exemptions -> Lua. An empty GALENA_RATE_LIMIT_EXEMPT means none.
exempt_lua=""
exempt_list=""
exempt_count=0
if [[ -n ${GALENA_RATE_LIMIT_EXEMPT:-} ]]; then
  IFS=',' read -r -a _ex <<< "$GALENA_RATE_LIMIT_EXEMPT"
  for cidr in "${_ex[@]}"; do
    [[ -n $cidr ]] || continue
    exempt_lua+="exemptNMG:addMask(\"${cidr}\")"$'\n'
    exempt_list+="\"${cidr}\", "
    exempt_count=$((exempt_count + 1))
  done
fi
[[ $exempt_count -gt 0 ]] || exempt_lua="-- no exempt ranges configured"
GALENA_EXEMPT_LUA="${exempt_lua%$'\n'}"
GALENA_EXEMPT_LIST="${exempt_list%, }"
GALENA_EXEMPT_COUNT="$exempt_count"
export GALENA_EXEMPT_LUA GALENA_EXEMPT_LIST GALENA_EXEMPT_COUNT
ok "rate-limit exemptions: ${exempt_count}"

# nftables admin rule: the address family has to match the CIDR or nft refuses.
# The quotes below are nftables syntax for a rule comment. This value is only
# ever written into a config file by envsubst, never evaluated as a command.
# shellcheck disable=SC2089,SC2090
if [[ $GALENA_ADMIN_CIDR == *:* ]]; then
  GALENA_NFT_ADMIN_RULES='        ip6 saddr '"${GALENA_ADMIN_CIDR}"' tcp dport 22 accept comment "SSH (admin)"'
else
  GALENA_NFT_ADMIN_RULES='        ip saddr '"${GALENA_ADMIN_CIDR}"' tcp dport 22 accept comment "SSH (admin)"'
fi
# shellcheck disable=SC2090
export GALENA_NFT_ADMIN_RULES

# --------------------------------------------------------------------------
# Packages
# --------------------------------------------------------------------------
step "Installing packages"

export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /etc/apt/keyrings
if [[ ! -s /etc/apt/keyrings/dnsdist-21-pub.asc ]]; then
  curl -fsSL --retry 3 --retry-delay 2 https://repo.powerdns.com/FD380FBB-pub.asc \
    -o /etc/apt/keyrings/dnsdist-21-pub.asc || die "could not fetch the PowerDNS signing key"
  grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/dnsdist-21-pub.asc \
    || die "PowerDNS signing key is not an armored PGP key"
  chmod 0644 /etc/apt/keyrings/dnsdist-21-pub.asc
fi

# dnsdist 2.1 is the current stable series; Debian's own dnsdist is far too old
# to have DoQ or DoH3 (incoming QUIC support landed in 1.9.0).
cat > /etc/apt/sources.list.d/dnsdist.list <<EOF
deb [signed-by=/etc/apt/keyrings/dnsdist-21-pub.asc] http://repo.powerdns.com/debian ${CODENAME}-dnsdist-21 main
EOF

cat > /etc/apt/preferences.d/dnsdist <<'EOF'
Package: dnsdist*
Pin: origin repo.powerdns.com
Pin-Priority: 600
EOF

apt-get update -qq || die "apt-get update failed"
apt-get install -y -qq --no-install-recommends \
  dnsdist \
  unbound \
  unbound-anchor \
  dns-root-data \
  certbot \
  python3-certbot-dns-route53 \
  nftables \
  gettext-base \
  knot-dnsutils \
  ca-certificates \
  curl >/dev/null || die "package installation failed"

ok "dnsdist $(dnsdist --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
ok "unbound $(unbound -V 2>&1 | grep -oE 'version [0-9.]+' | head -1)"
ok "certbot $(certbot --version 2>&1 | grep -oE '[0-9.]+' | head -1)"

# --------------------------------------------------------------------------
# Hard requirement: this build must actually speak QUIC
# --------------------------------------------------------------------------
step "Verifying dnsdist QUIC support"
ver=$(dnsdist --version 2>&1)
missing=()
grep -q 'dns-over-quic' <<< "$ver" || missing+=("dns-over-quic (DoQ)")
grep -q 'dns-over-http3' <<< "$ver" || missing+=("dns-over-http3 (DoH3)")
grep -q 'dns-over-tls' <<< "$ver" || missing+=("dns-over-tls (DoT)")
grep -q 'dns-over-https' <<< "$ver" || missing+=("dns-over-https (DoH)")
if ((${#missing[@]})); then
  printf '%s\n' "$ver" >&2
  die "this dnsdist lacks: ${missing[*]}
The official PowerDNS packages statically link Cloudflare quiche and do have
these. Getting here usually means apt resolved dnsdist from Debian instead of
repo.powerdns.com. Check: apt-cache policy dnsdist"
fi
ok "DoT, DoH, DoQ and DoH3 all compiled in"

# The dnsdist package creates /etc/dnsdist owned by root:root. The daemon runs as
# _dnsdist and must be able to traverse it to reach both dnsdist.conf and tls/,
# so fix the group here — before the ACME step populates tls/.
getent group _dnsdist >/dev/null || die "the _dnsdist group does not exist — did the dnsdist package install?"
install -d -m 0750 -o root -g _dnsdist /etc/dnsdist
ok "/etc/dnsdist traversable by _dnsdist"

# --------------------------------------------------------------------------
# Logging: RAM only
# --------------------------------------------------------------------------
step "Configuring volatile logging"
require_vars GALENA_JOURNAL_RUNTIME_MAX_USE
install -d -m 0755 /etc/systemd/journald.conf.d
envsubst '${GALENA_JOURNAL_RUNTIME_MAX_USE}' \
  < "${REPO}/systemd/journald-privacy.conf" > /etc/systemd/journald.conf.d/00-galena-privacy.conf
systemctl restart systemd-journald
# Storage=volatile means journald will not recreate this, so removing it is
# enough; there is no need for a sentinel file.
rm -rf /var/log/journal
ok "journald Storage=volatile, RuntimeMaxUse=${GALENA_JOURNAL_RUNTIME_MAX_USE:-16M}"

if dpkg -l rsyslog 2>/dev/null | grep -q '^ii'; then
  apt-get purge -y -qq rsyslog >/dev/null
  ok "removed rsyslog (it would persist logs to /var/log)"
fi

# --------------------------------------------------------------------------
# Firewall
# --------------------------------------------------------------------------
step "Applying nftables ruleset"
require_vars GALENA_NFT_ADMIN_RULES
envsubst '${GALENA_NFT_ADMIN_RULES}' \
  < "${REPO}/nftables/nftables.conf.tmpl" > /etc/nftables.conf
chmod 0750 /etc/nftables.conf
nft -c -f /etc/nftables.conf || die "nftables ruleset is invalid"
systemctl enable --now nftables >/dev/null 2>&1
nft -f /etc/nftables.conf || die "could not apply nftables ruleset"
ok "input policy drop; 443+853 tcp/udp open, 22 from ${GALENA_ADMIN_CIDR}"

# --------------------------------------------------------------------------
# unbound
# --------------------------------------------------------------------------
step "Configuring unbound"

install -d -m 0755 -o unbound -g unbound "$RPZ_DIR"

# Zone files must exist before unbound starts. Placeholders keep startup fast and
# let the resolver work (unfiltered) while the real lists download.
mk_placeholder() {
  cat > "$1" <<'EOF'
$TTL 3600
@   SOA localhost. root.localhost. 1 3600 600 86400 3600
@   NS  localhost.
EOF
  chown unbound:unbound "$1"
}

install -m 0644 -o unbound -g unbound "${REPO}/unbound/rpz/allowlist.rpz" "${RPZ_DIR}/allowlist.rpz"
for zone in $GALENA_RPZ_ZONES; do
  [[ -s "${RPZ_DIR}/${zone}.rpz" ]] || mk_placeholder "${RPZ_DIR}/${zone}.rpz"
done

# Generated rather than templated, because ORDER IS SEMANTIC: in RPZ a passthru
# is a match, and a match stops evaluation of every later zone. The allowlist is
# emitted first, unconditionally, so it always wins.
install -d -m 0755 /etc/unbound/unbound.conf.d
{
  echo "# Generated by bootstrap.sh from ${MANIFEST}. Do not edit on the node."
  echo "# Order is significant: the allowlist must stay first."
  echo
  echo "rpz:"
  echo "    name: allowlist.rpz.galena"
  echo "    zonefile: \"${RPZ_DIR}/allowlist.rpz\""
  echo "    rpz-log: no"
  echo
  for zone in $GALENA_RPZ_ZONES; do
    echo "rpz:"
    echo "    name: ${zone}.rpz.galena"
    echo "    zonefile: \"${RPZ_DIR}/${zone}.rpz\""
    echo "    rpz-log: no"
    echo
  done
} > /etc/unbound/unbound.conf.d/galena-rpz.conf

# Resolution posture. GALENA_FORWARD_UPSTREAMS is deliberately allowed to be
# empty (= recurse from the root), so it is NOT passed to require_vars; only the
# rendered block is, and that always carries at least a comment.
#
# forward-first: no is the load-bearing line. With it, an unreachable upstream is
# a SERVFAIL. Without it, unbound would quietly fall back to recursing — which
# means cleartext query names on the wire at the exact moment nobody is looking.
# A privacy posture that degrades silently is not a posture.
if [[ -n ${GALENA_FORWARD_UPSTREAMS:-} ]]; then
  GALENA_FORWARD_BLOCK=$(
    echo "forward-zone:"
    echo "    name: \".\""
    echo "    forward-tls-upstream: yes"
    echo "    forward-first: no"
    for u in ${GALENA_FORWARD_UPSTREAMS}; do
      echo "    forward-addr: ${u}"
    done
  )
  n_up=$(wc -w <<< "${GALENA_FORWARD_UPSTREAMS}")
  ok "forwarding over DoT to ${n_up} upstream(s): ${GALENA_FORWARD_UPSTREAMS}"
else
  GALENA_FORWARD_BLOCK="# No forward zone: unbound recurses from the root (forward_tls_upstreams = [])."
  ok "full recursion from the root (no forwarding configured)"
fi
export GALENA_FORWARD_BLOCK

# Debian ships its own config fragments; ours is the whole configuration.
rm -f /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf
require_vars GALENA_NUM_THREADS GALENA_CACHE_SLABS GALENA_UNBOUND_MSG_CACHE GALENA_UNBOUND_RRSET_CACHE \
  GALENA_FORWARD_BLOCK
envsubst '${GALENA_NUM_THREADS} ${GALENA_CACHE_SLABS} ${GALENA_UNBOUND_MSG_CACHE} ${GALENA_UNBOUND_RRSET_CACHE} ${GALENA_FORWARD_BLOCK}' \
  < "${REPO}/unbound/unbound.conf.tmpl" > /etc/unbound/unbound.conf

install -d -m 0755 /etc/systemd/system/unbound.service.d
require_vars GALENA_UNBOUND_MEMORY_MAX
envsubst '${GALENA_UNBOUND_MEMORY_MAX}' \
  < "${REPO}/systemd/unbound.service.d/hardening.conf" > /etc/systemd/system/unbound.service.d/hardening.conf

# Trust anchor. unbound-anchor exits 1 when it merely had to bootstrap the key,
# which is not an error on a fresh node — hence the tolerated failure. But a
# tolerated failure must not be an unnoticed one: the assertion below is what
# actually guarantees DNSSEC can validate. (unbound-anchor is a SEPARATE Debian
# package from unbound; without it this call silently did nothing and the anchor
# only existed because dns-root-data happened to seed it.)
unbound-anchor -a /var/lib/unbound/root.key || warn "unbound-anchor reported a problem (normal on a first run)"
if [[ ! -s /var/lib/unbound/root.key ]]; then
  # Fall back to the copy dns-root-data ships before giving up.
  [[ -s /usr/share/dns/root.key ]] \
    && install -m 0644 -o unbound -g unbound /usr/share/dns/root.key /var/lib/unbound/root.key \
    || die "no DNSSEC trust anchor at /var/lib/unbound/root.key — validation would be impossible"
fi
chown unbound:unbound /var/lib/unbound/root.key
ok "DNSSEC trust anchor present ($(wc -c < /var/lib/unbound/root.key) bytes)"

# Debian ships unbound-resolvconf.service, which runs `unbound-helper
# resolvconf_start` and pushes the DHCP-supplied nameservers into unbound as a
# root forward zone AT RUNTIME, via unbound-control. Nothing appears in any
# config file. On Hetzner that silently turns full recursion into forwarding to
# 185.12.64.1/.2 — so the provider sees every query name, which is the single
# thing this resolver exists to prevent. Mask it, and divert the resolvconf hook
# so a package upgrade cannot quietly restore it.
systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true
systemctl mask unbound-resolvconf.service >/dev/null 2>&1 || true
if [[ -x /etc/resolvconf/update.d/unbound ]]; then
  dpkg-divert --local --rename --add /etc/resolvconf/update.d/unbound >/dev/null 2>&1 || true
fi
ok "unbound-resolvconf masked (it would force forwarding to the provider's resolvers)"

unbound-checkconf /etc/unbound/unbound.conf >/dev/null || die "unbound configuration is invalid"
ok "configuration valid ($(grep -c '^rpz:' /etc/unbound/unbound.conf.d/galena-rpz.conf) policy zones)"

systemctl daemon-reload
systemctl enable unbound >/dev/null 2>&1
systemctl restart unbound

# Wait for it to actually answer rather than assuming systemd's "active" means ready.
for _ in $(seq 1 30); do
  if dig +short +time=2 +tries=1 @127.0.0.1 -p 53 nlnetlabs.nl A >/dev/null 2>&1; then break; fi
  sleep 1
done
dig +short +time=3 +tries=1 @127.0.0.1 -p 53 nlnetlabs.nl A >/dev/null 2>&1 \
  || die "unbound is not answering on 127.0.0.1:53 — check: journalctl -u unbound"
ok "unbound answering on loopback"

# Verify the posture that was actually configured, because the failure mode in
# both directions is silent. unbound-resolvconf (masked above) injects the
# PROVIDER's resolvers as a root forward zone at runtime via unbound-control, in
# cleartext, visible in no config file — so "is there a forwarder" is not the
# question. "Is the forwarder the one we chose, over TLS" is.
fwd=$(unbound-control list_forwards 2>/dev/null | grep -v '^[[:space:]]*$' || true)
if [[ -n ${GALENA_FORWARD_UPSTREAMS:-} ]]; then
  [[ -n $fwd ]] || die "unbound has no forward zone, but forward_tls_upstreams is set.
It is therefore recursing in cleartext instead of forwarding over TLS, which is
the opposite of the configured privacy posture. Check: unbound-checkconf"

  grep -qE '^\s*forward-tls-upstream:\s*yes' /etc/unbound/unbound.conf \
    || die "forward zone present but forward-tls-upstream is not yes — query names would leave in cleartext"
  grep -qE '^\s*forward-first:\s*no' /etc/unbound/unbound.conf \
    || die "forward-first is not 'no' — unbound would silently fall back to cleartext recursion when the upstream is unreachable"

  matched=0 total=0
  for u in ${GALENA_FORWARD_UPSTREAMS}; do
    total=$((total + 1))
    # Either the address or the #tls-auth-name is enough. Matching on both
    # forms means a difference in list_forwards' output format cannot fail this,
    # while provider resolvers injected by resolvconf match neither.
    if grep -qF "${u%%@*}" <<< "$fwd" || { [[ $u == *#* ]] && grep -qF "${u##*#}" <<< "$fwd"; }; then
      matched=$((matched + 1))
    fi
  done
  ((matched > 0)) || die "unbound's forward zone matches none of the configured upstreams.
  configured: ${GALENA_FORWARD_UPSTREAMS}
  running:    $(tr '\n' ' ' <<< "$fwd")
Something else set this — most likely unbound-resolvconf came back."
  ((matched == total)) \
    && ok "forwarding over authenticated DoT (${matched}/${total} upstreams active)" \
    || warn "only ${matched}/${total} configured upstreams are in the running forward zone"
else
  # Full recursion: clear anything injected before the mask took effect, then
  # assert nothing remains.
  unbound-control forward off >/dev/null 2>&1 || true
  fwd=$(unbound-control list_forwards 2>/dev/null | grep -v '^[[:space:]]*$' || true)
  [[ -z $fwd ]] || die "unbound still has a forward zone configured, so it is NOT recursing:
  ${fwd}
Something re-added it after unbound-resolvconf was masked. Investigate before
serving traffic: this sends every query name to a third-party resolver."
  ok "no forwarders: unbound resolves from the root"
fi

# --------------------------------------------------------------------------
# Host resolver
# --------------------------------------------------------------------------
step "Pointing the host at its own resolver"
# Only now that unbound answers. Doing this earlier would break apt and certbot.
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
# Managed by galena-dns. The host resolves through its own unbound instance, so
# no host lookup (apt, ACME, blocklist fetch) is sent to a third-party resolver.
nameserver 127.0.0.1
nameserver ::1
options edns0 trust-ad
EOF
# Immutable so DHCP and cloud-init cannot quietly point us back at Hetzner.
chattr +i /etc/resolv.conf 2>/dev/null || warn "could not set immutable bit on /etc/resolv.conf"
getent hosts deb.debian.org >/dev/null || die "host name resolution broke after switching resolv.conf"
ok "/etc/resolv.conf -> 127.0.0.1 (immutable)"

# --------------------------------------------------------------------------
# Blocklists
# --------------------------------------------------------------------------
step "Loading RPZ blocklists"
install -m 0755 "${REPO}/bin/rpz-update.sh" /usr/local/sbin/galena-rpz-update
if ! "${REPO}/bin/rpz-update.sh"; then
  warn "blocklist load reported problems — the resolver is running but may be unfiltered"
  warn "investigate with: ${REPO}/bin/rpz-update.sh"
fi

install -m 0644 "${REPO}/systemd/rpz-update.service" /etc/systemd/system/rpz-update.service
require_vars GALENA_RPZ_UPDATE_INTERVAL
envsubst '${GALENA_RPZ_UPDATE_INTERVAL}' \
  < "${REPO}/systemd/rpz-update.timer" > /etc/systemd/system/rpz-update.timer
systemctl daemon-reload
systemctl enable --now rpz-update.timer >/dev/null 2>&1
ok "refresh timer enabled (every ${GALENA_RPZ_UPDATE_INTERVAL:-8h})"

# --------------------------------------------------------------------------
# TLS
# --------------------------------------------------------------------------
step "Obtaining TLS certificate (ACME DNS-01 via Route 53)"
install -m 0755 "${REPO}/bin/acme-deploy-hook.sh" /usr/local/sbin/galena-acme-deploy

AWS_CREDS=/etc/letsencrypt/aws.credentials
[[ -s $AWS_CREDS ]] \
  || die "${AWS_CREDS} missing — 'make deploy' installs it from \$AWS_ACCESS_KEY_ID / \$AWS_SECRET_ACCESS_KEY"
chmod 0600 "$AWS_CREDS"
grep -q 'aws_access_key_id' "$AWS_CREDS" \
  || die "${AWS_CREDS} has no aws_access_key_id"

# Renewal runs from certbot.timer with a clean environment and the plugin has no
# --credentials flag, so the drop-in is what keeps renewal working in 60 days.
install -d -m 0755 /etc/systemd/system/certbot.service.d
install -m 0644 "${REPO}/systemd/certbot.service.d/aws-credentials.conf" \
  /etc/systemd/system/certbot.service.d/aws-credentials.conf
systemctl daemon-reload

# Same values for this first, interactive issuance.
export AWS_SHARED_CREDENTIALS_FILE="$AWS_CREDS"
export AWS_CONFIG_FILE="$AWS_CREDS"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

staging_arg=()
[[ ${GALENA_ACME_STAGING:-0} == 1 ]] && staging_arg=(--staging)

LIVE_CERT="/etc/letsencrypt/live/${GALENA_DOMAIN}/fullchain.pem"
want_staging=${GALENA_ACME_STAGING:-0}

# A certificate already being present is not sufficient: it also has to come from
# the CA we now want. Without this, the documented "flip acme_staging to false and
# re-deploy" would skip issuance and serve the untrusted staging certificate
# forever. Let's Encrypt's staging intermediate carries STAGING in its issuer.
if [[ -s $LIVE_CERT ]]; then
  if openssl x509 -in "$LIVE_CERT" -noout -issuer 2>/dev/null | grep -qi staging; then
    have_staging=1
  else
    have_staging=0
  fi
  if [[ $have_staging != "$want_staging" ]]; then
    warn "existing certificate is from the $([[ $have_staging == 1 ]] && echo staging || echo production) CA but acme_staging=${want_staging}"
    warn "removing it so the correct CA issues a replacement"
    # dnsdist keeps serving its own copy in /etc/dnsdist/tls meanwhile, so there
    # is no gap in service between the delete and the new issuance.
    certbot delete --cert-name "$GALENA_DOMAIN" --non-interactive || true
  fi
fi

if [[ -s $LIVE_CERT ]]; then
  ok "certificate already present from the requested CA; skipping issuance"
else
  # certbot-dns-route53 polls Route 53's GetChange until the record set is
  # INSYNC, so there is no propagation-seconds flag to tune and none is needed.
  certbot certonly \
    --non-interactive --agree-tos --no-eff-email \
    --email "$GALENA_ACME_EMAIL" \
    --dns-route53 \
    --key-type ecdsa \
    -d "$GALENA_DOMAIN" \
    "${staging_arg[@]}" \
    || die "certbot failed. Common causes: the IAM key lacks
route53:ChangeResourceRecordSets on the hosted zone containing ${GALENA_DOMAIN},
route53:ListHostedZones or route53:GetChange on *, or ${GALENA_DOMAIN} is not in
a Route 53 hosted zone at all."
  ok "certificate issued for ${GALENA_DOMAIN}"
fi

# Renewal must reload dnsdist: it does not notice new certificate files by itself.
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
ln -sf /usr/local/sbin/galena-acme-deploy /etc/letsencrypt/renewal-hooks/deploy/galena

# Stagger renewal so multiple nodes never run DNS-01 at the same time.
#
# Every node holds its own certificate for the SAME hostname, so every node
# validates against the same _acme-challenge TXT record. certbot's route53 plugin
# tracks challenge values in a process-local dict and sends UPSERT with only its
# own values, without reading what is already in the record set — see
# _change_txt_record in certbot_dns_route53. Two nodes validating at once means
# the second overwrites the first's TXT, the first fails validation, and cleanup
# can delete the survivor's record as well.
#
# Debian ships OnCalendar=00,12:00:00 with RandomizedDelaySec=43200, so two nodes
# pick independent times in the same 12h window. Nodes deployed together also have
# certificates that come due the same day, so the windows line up. Rare, but it
# fails into a volatile journal that a reboot erases.
#
# node.env is identical on every node, so the offset is derived from the node's
# own hostname instead: ~720 distinct slots, no coordination, stable across
# deploys. A narrow RandomizedDelaySec keeps jitter inside the slot.
stagger=$(hostname | cksum | cut -d' ' -f1)
install -d -m 0755 /etc/systemd/system/certbot.timer.d
cat > /etc/systemd/system/certbot.timer.d/galena-stagger.conf <<EOF
[Timer]
# Empty value first: systemd appends to OnCalendar otherwise, it does not replace.
OnCalendar=
OnCalendar=*-*-* $((stagger % 12)),$((stagger % 12 + 12)):$((stagger / 12 % 60)):00
RandomizedDelaySec=600
EOF
systemctl daemon-reload
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
ok "renewal staggered to $(printf '%02d:%02d' "$((stagger % 12))" "$((stagger / 12 % 60))") and $(printf '%02d:%02d' "$((stagger % 12 + 12))" "$((stagger / 12 % 60))") UTC (±10m)"
RENEWED_LINEAGE="/etc/letsencrypt/live/${GALENA_DOMAIN}" /usr/local/sbin/galena-acme-deploy
ok "renewal hook installed"

# --------------------------------------------------------------------------
# dnsdist
# --------------------------------------------------------------------------
step "Configuring dnsdist"
# dnsdist console key. Generated on the node and kept here, so it never passes
# through Terraform state or Hetzner's metadata service.
KEYFILE=/etc/dnsdist/console.key
if [[ ! -s $KEYFILE ]]; then
  (
    umask 077
    dd if=/dev/urandom bs=32 count=1 status=none | base64 > "$KEYFILE"
  )
  ok "generated dnsdist console key"
else
  ok "reusing existing dnsdist console key"
fi
GALENA_CONSOLE_KEY=$(tr -d '\n' < "$KEYFILE")
export GALENA_CONSOLE_KEY

if [[ ${GALENA_ENABLE_METRICS:-0} == 1 ]]; then
  api_key_file=/etc/dnsdist/webserver.key
  if [[ ! -s $api_key_file ]]; then
    (
      umask 077
      dd if=/dev/urandom bs=24 count=1 status=none | base64 > "$api_key_file"
    )
  fi
  GALENA_METRICS_BLOCK=$(
    cat <<METRICS
-- Aggregate metrics only, bound to loopback. Reach it with: make tunnel
webserver("127.0.0.1:8083")
setWebserverConfig({
  apiKey = "$(tr -d '\n' < "$api_key_file")",
  acl = { "127.0.0.1/32", "::1/128" },
  statsRequireAuthentication = true,
})
METRICS
  )
  warn "localhost metrics ENABLED — the HTML console can surface topQueries from the ring"
else
  GALENA_METRICS_BLOCK="-- Metrics disabled (enable_localhost_metrics = false)."
fi
export GALENA_METRICS_BLOCK

require_vars GALENA_DYNBLOCK_RING_ENTRIES GALENA_MAX_QPS_PER_IP GALENA_MAX_QPS_BURST_PER_IP GALENA_DYNBLOCK_QPS \
  GALENA_TUNNEL_MAX_QNAME_BYTES GALENA_TUNNEL_REFUSE_QTYPES \
  GALENA_DYNBLOCK_WINDOW GALENA_DYNBLOCK_DURATION GALENA_EXEMPT_LUA GALENA_EXEMPT_COUNT \
  GALENA_CONSOLE_KEY GALENA_METRICS_BLOCK GALENA_PACKET_CACHE_ENTRIES
envsubst '${GALENA_DYNBLOCK_RING_ENTRIES} ${GALENA_MAX_QPS_PER_IP} ${GALENA_MAX_QPS_BURST_PER_IP} ${GALENA_TUNNEL_MAX_QNAME_BYTES} ${GALENA_TUNNEL_REFUSE_QTYPES} ${GALENA_DYNBLOCK_QPS} ${GALENA_DYNBLOCK_WINDOW} ${GALENA_DYNBLOCK_DURATION} ${GALENA_EXEMPT_LUA} ${GALENA_EXEMPT_LIST} ${GALENA_EXEMPT_COUNT} ${GALENA_CONSOLE_KEY} ${GALENA_METRICS_BLOCK} ${GALENA_PACKET_CACHE_ENTRIES}' \
  < "${REPO}/dnsdist/dnsdist.conf.tmpl" > /etc/dnsdist/dnsdist.conf
chown root:_dnsdist /etc/dnsdist/dnsdist.conf
chmod 0640 /etc/dnsdist/dnsdist.conf

dnsdist --check-config --config /etc/dnsdist/dnsdist.conf >/dev/null 2>&1 \
  || die "dnsdist configuration is invalid: $(dnsdist --check-config --config /etc/dnsdist/dnsdist.conf 2>&1 | tail -5)"

install -d -m 0755 /etc/systemd/system/dnsdist.service.d
install -m 0644 "${REPO}/systemd/dnsdist.service.d/hardening.conf" \
  /etc/systemd/system/dnsdist.service.d/hardening.conf
systemctl daemon-reload
systemctl enable dnsdist >/dev/null 2>&1
systemctl restart dnsdist

sleep 2
systemctl is-active --quiet dnsdist || die "dnsdist did not start — journalctl -u dnsdist"
ok "dnsdist running"

# --------------------------------------------------------------------------
# Stats collector keys
# --------------------------------------------------------------------------
step "Stats collector keys"

install -D -m 0755 "${REPO}/bin/dump-stats.sh" /opt/galena/bin/dump-stats.sh
install -d -m 0700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

SC_BEGIN="# BEGIN galena stats collector (managed by bootstrap.sh)"
SC_END="# END galena stats collector"

# Only the marked block is rewritten, so the admin key Hetzner injected when the
# server was created is never touched. Losing that would mean losing the only
# way back in, and server ssh_keys cannot be changed without a replacement.
sc_tmp=$(mktemp)
awk -v b="$SC_BEGIN" -v e="$SC_END" '
  $0 == b { skip = 1; next }
  $0 == e { skip = 0; next }
  !skip   { print }
' /root/.ssh/authorized_keys > "$sc_tmp"

if [[ -n ${GALENA_STATS_SSH_KEYS_B64:-} ]] \
  && sc_keys=$(printf '%s' "$GALENA_STATS_SSH_KEYS_B64" | base64 -d 2>/dev/null) \
  && [[ -n ${sc_keys//[[:space:]]/} ]]; then
  {
    printf '%s\n' "$SC_BEGIN"
    while IFS= read -r sc_key; do
      [[ -n ${sc_key//[[:space:]]/} ]] || continue
      # restrict = no pty, no agent or port forwarding, no user rc. With the
      # forced command that leaves exactly one capability: print dumpStats().
      printf 'command="/opt/galena/bin/dump-stats.sh",restrict %s\n' "$sc_key"
    done <<< "$sc_keys"
    printf '%s\n' "$SC_END"
  } >> "$sc_tmp"
  ok "$(grep -c '^command="/opt/galena/bin/dump-stats.sh"' "$sc_tmp") collector key(s), pinned to dump-stats.sh"
else
  ok "no collector keys configured (managed block removed if it existed)"
fi

install -m 0600 "$sc_tmp" /root/.ssh/authorized_keys
rm -f "$sc_tmp"

# Prove the pinning rather than trust the file we just wrote: a key in the
# managed block without a forced command would be a root shell on a resolver
# handed to an analytics host.
if grep -qF "$SC_BEGIN" /root/.ssh/authorized_keys; then
  if awk -v b="$SC_BEGIN" -v e="$SC_END" '
       $0 == b { inb = 1; next }
       $0 == e { inb = 0; next }
       inb && $0 !~ /^command="\/opt\/galena\/bin\/dump-stats\.sh",restrict / { bad = 1 }
       END { exit !bad }
     ' /root/.ssh/authorized_keys; then
    die "a key in the managed collector block is not pinned to dump-stats.sh"
  fi
  ok "every collector key is command-pinned and restricted"
fi

# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------
step "Verifying"

for spec in "tcp:443:DoH" "tcp:853:DoT" "udp:443:DoH3" "udp:853:DoQ"; do
  IFS=: read -r proto port label <<< "$spec"
  flag=$([[ $proto == tcp ]] && echo -ltn || echo -lun)
  if ss "$flag" 2>/dev/null | grep -qE "[:.]${port}\b"; then
    ok "${label} listening on ${proto}/${port}"
  else
    die "${label} is not listening on ${proto}/${port}"
  fi
done

# The whole point: plain DNS must not be reachable from anywhere but loopback.
if ss -lntu 2>/dev/null | awk '{print $5}' | grep -E ':53$' | grep -qvE '^(127\.0\.0\.1|\[::1\])'; then
  ss -lntu | grep ':53'
  die "something is listening on port 53 on a non-loopback address"
fi
ok "port 53 is loopback-only"

mem_avail_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
unbound_rss_kb=$(ps -o rss= -C unbound 2>/dev/null | awk '{s+=$1} END{print s+0}')
printf '    %s+%s unbound RSS %s MB, %s MB available\n' "$G" "$N" \
  "$((unbound_rss_kb / 1024))" "$((mem_avail_kb / 1024))"
if ((mem_avail_kb < 262144)); then
  warn "under 256 MB available. Lower unbound_msg_cache_size and"
  warn "unbound_rrset_cache_size in terraform.tfvars, or use a larger node."
fi

printf '\n%sgalena-dns is up on %s%s\n' "$B" "$GALENA_DOMAIN" "$N"
printf 'Next: make audit && make test\n'
