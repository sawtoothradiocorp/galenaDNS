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

# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
step "Loading configuration"
[[ -r "${REPO}/node.env" ]] || die "${REPO}/node.env missing — was this node created by Terraform?"
# shellcheck source=/dev/null
source "${REPO}/node.env"

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
  dns-root-data \
  certbot \
  python3-certbot-dns-cloudflare \
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

# Debian ships its own config fragments; ours is the whole configuration.
rm -f /etc/unbound/unbound.conf.d/root-auto-trust-anchor-file.conf
envsubst '${GALENA_NUM_THREADS} ${GALENA_CACHE_SLABS} ${GALENA_UNBOUND_MSG_CACHE} ${GALENA_UNBOUND_RRSET_CACHE}' \
  < "${REPO}/unbound/unbound.conf.tmpl" > /etc/unbound/unbound.conf

install -d -m 0755 /etc/systemd/system/unbound.service.d
envsubst '${GALENA_UNBOUND_MEMORY_MAX}' \
  < "${REPO}/systemd/unbound.service.d/hardening.conf" > /etc/systemd/system/unbound.service.d/hardening.conf

# Trust anchor. unbound-anchor exits 1 when it had to bootstrap the key, which is
# not an error on a fresh node.
unbound-anchor -a /var/lib/unbound/root.key || true
chown unbound:unbound /var/lib/unbound/root.key

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
envsubst '${GALENA_RPZ_UPDATE_INTERVAL}' \
  < "${REPO}/systemd/rpz-update.timer" > /etc/systemd/system/rpz-update.timer
systemctl daemon-reload
systemctl enable --now rpz-update.timer >/dev/null 2>&1
ok "refresh timer enabled (every ${GALENA_RPZ_UPDATE_INTERVAL:-8h})"

# --------------------------------------------------------------------------
# TLS
# --------------------------------------------------------------------------
step "Obtaining TLS certificate (ACME DNS-01 via Cloudflare)"
install -m 0755 "${REPO}/bin/acme-deploy-hook.sh" /usr/local/sbin/galena-acme-deploy

[[ -s /etc/letsencrypt/cloudflare.ini ]] \
  || die "/etc/letsencrypt/cloudflare.ini missing — 'make deploy' installs it from \$CLOUDFLARE_API_TOKEN"
chmod 0600 /etc/letsencrypt/cloudflare.ini
grep -q 'dns_cloudflare_api_token' /etc/letsencrypt/cloudflare.ini \
  || die "cloudflare.ini must use dns_cloudflare_api_token (certbot 4.x removed global-key auth)"

staging_arg=()
[[ ${GALENA_ACME_STAGING:-0} == 1 ]] && staging_arg=(--staging)

if [[ -s "/etc/letsencrypt/live/${GALENA_DOMAIN}/fullchain.pem" ]]; then
  ok "certificate already present; skipping issuance"
else
  certbot certonly \
    --non-interactive --agree-tos --no-eff-email \
    --email "$GALENA_ACME_EMAIL" \
    --dns-cloudflare \
    --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    --key-type ecdsa \
    -d "$GALENA_DOMAIN" \
    "${staging_arg[@]}" \
    || die "certbot failed. Common causes: the API token lacks Zone:DNS:Edit on
the zone holding ${GALENA_DOMAIN}, or the zone is not actually on Cloudflare."
  ok "certificate issued for ${GALENA_DOMAIN}"
fi

# Renewal must reload dnsdist: it does not notice new certificate files by itself.
install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
ln -sf /usr/local/sbin/galena-acme-deploy /etc/letsencrypt/renewal-hooks/deploy/galena
systemctl enable --now certbot.timer >/dev/null 2>&1 || true
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

envsubst '${GALENA_DYNBLOCK_RING_ENTRIES} ${GALENA_MAX_QPS_PER_IP} ${GALENA_DYNBLOCK_QPS} ${GALENA_DYNBLOCK_WINDOW} ${GALENA_DYNBLOCK_DURATION} ${GALENA_EXEMPT_LUA} ${GALENA_EXEMPT_LIST} ${GALENA_EXEMPT_COUNT} ${GALENA_CONSOLE_KEY} ${GALENA_METRICS_BLOCK}' \
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
  warn "under 256 MB available. The threat feed is large; consider swapping"
  warn "rpz/tif.medium.txt for rpz/tif.mini.txt in terraform.tfvars."
fi

printf '\n%sgalena-dns is up on %s%s\n' "$B" "$GALENA_DOMAIN" "$N"
printf 'Next: make audit && make test\n'
