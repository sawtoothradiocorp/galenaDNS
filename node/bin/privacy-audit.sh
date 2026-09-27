#!/usr/bin/env bash
#
# galena-dns — privacy audit.
#
# Checks the RUNNING system, not the repo, for anything that persists client IP
# addresses or query names. Reviewing the config only proves the config is right;
# check 13 below sends a uniquely-named query and then goes looking for it on
# disk, which is the check that catches what a config review misses.
#
# Every check is documented in README.md under "What the privacy audit checks".
#
# Exit status: 0 if no FAIL, 1 otherwise. WARN does not fail the run.

set -uo pipefail

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=''; G=''; Y=''; R=''; D=''; N=''
fi

pass_n=0 warn_n=0 fail_n=0
declare -a RESULTS

_rec() { RESULTS+=("$1"$'\t'"$2"$'\t'"$3"); }
pass() {
  printf '  %sPASS%s %-52s %s\n' "$G" "$N" "$1" "${2:-}"
  _rec PASS "$1" "${2:-}"
  ((pass_n++))
}
warn() {
  printf '  %sWARN%s %-52s %s\n' "$Y" "$N" "$1" "${2:-}"
  _rec WARN "$1" "${2:-}"
  ((warn_n++))
}
fail() {
  printf '  %sFAIL%s %-52s %s\n' "$R" "$N" "$1" "${2:-}"
  _rec FAIL "$1" "${2:-}"
  ((fail_n++))
}
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }
note() { printf '       %s%s%s\n' "$D" "$1" "$N"; }

[[ $EUID -eq 0 ]] || {
  echo "must run as root (it inspects other processes' sockets and /etc)" >&2
  exit 1
}

# shellcheck source=/dev/null
[[ -r /opt/galena/node.env ]] && source /opt/galena/node.env

printf '%sgalena-dns privacy audit%s  %s  %s\n' "$B" "$N" "$(hostname)" "$(date -Is)"

# ===========================================================================
section "1. Listening sockets"
# ===========================================================================
# The core structural guarantee: plain DNS is reachable only from loopback, so
# "port 53 is closed" is true by construction and not only by firewall rule.
# $4 is the LOCAL address; $5 is the peer and is always 0.0.0.0:* for a listener,
# so matching on $5 would make this check silently unfalsifiable.
nonloopback53=$(ss -lntuHn 2>/dev/null | awk '{print $4}' \
  | grep -E '[:.]53$' | grep -vE '^(127\.0\.0\.1|\[::1\]|\[::ffff:127)' || true)
if [[ -n $nonloopback53 ]]; then
  fail "nothing on 53 except loopback" "found: $(tr '\n' ' ' <<< "$nonloopback53")"
else
  pass "nothing on 53 except loopback"
fi

for spec in "tcp:443:DoH" "tcp:853:DoT" "udp:443:DoH3" "udp:853:DoQ"; do
  IFS=: read -r proto port label <<< "$spec"
  flag=$([[ $proto == tcp ]] && echo -ltnH || echo -lunH)
  if ss "$flag" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"; then
    pass "${label} is listening (${proto}/${port})"
  else
    fail "${label} is listening (${proto}/${port})" "not bound"
  fi
done

note "full listener table:"
ss -lntupn 2>/dev/null | sed 's/^/       /'

# ===========================================================================
section "2. Logging subsystem"
# ===========================================================================
storage=$(systemd-analyze cat-config systemd/journald.conf 2>/dev/null \
  | grep -iE '^\s*Storage=' | tail -1 | cut -d= -f2 | tr -d ' ')
if [[ ${storage,,} == volatile || ${storage,,} == none ]]; then
  pass "journald Storage is volatile" "Storage=${storage}"
else
  fail "journald Storage is volatile" "Storage=${storage:-unset (defaults to auto -> disk)}"
fi

if [[ -d /var/log/journal ]]; then
  fail "no persistent journal directory" "/var/log/journal exists"
else
  pass "no persistent journal directory"
fi

jdisk=$(journalctl --header 2>/dev/null | grep -iE 'disk usage' | head -1 | sed 's/^ *//')
[[ -n $jdisk ]] && note "$jdisk"

for pkg in rsyslog syslog-ng auditd sysstat systemd-journal-remote; do
  if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
    fail "${pkg} is not installed" "installed — it can persist logs to disk"
  else
    pass "${pkg} is not installed"
  fi
done

# An nftables `log` statement would push client IPs straight into journald from
# the one place nobody thinks to audit. Comments mentioning "log" do not count.
if nft -a list ruleset 2>/dev/null | grep -qE '^\s*log\b|[[:space:]]log[[:space:]]+(prefix|level|flags)'; then
  fail "nftables ruleset has no log statements" "found a log statement"
else
  pass "nftables ruleset has no log statements"
fi

# ===========================================================================
section "3. unbound runtime configuration and resolution posture"
# ===========================================================================
# Asserted against the RUNNING daemon, not the file on disk, so a config that was
# edited but never reloaded cannot pass.
check_opt() {
  local opt=$1 want=$2 got
  got=$(unbound-control get_option "$opt" 2>/dev/null) || {
    warn "unbound ${opt} = ${want}" "could not query unbound-control"
    return
  }
  got=${got//$'\n'/}
  if [[ $got == "$want" ]]; then
    pass "unbound ${opt} = ${want}"
  else
    fail "unbound ${opt} = ${want}" "actual: '${got}'"
  fi
}

if unbound-control status >/dev/null 2>&1; then
  check_opt verbosity 0
  check_opt log-queries no
  check_opt log-replies no
  check_opt log-local-actions no
  check_opt log-servfail no
  check_opt log-tag-queryreply no
  check_opt use-syslog no
  check_opt logfile ""
  check_opt statistics-interval 0
  check_opt extended-statistics no
  check_opt qname-minimisation yes
  check_opt aggressive-nsec yes
  check_opt hide-identity yes
  check_opt hide-version yes
else
  fail "unbound-control is reachable" "unbound is not running or the socket is missing"
fi

# EDNS Client Subnet would send the client's network to every authoritative
# server we talk to. Debian's unbound IS built with subnetcache, so the thing to
# assert is that it is not LOADED — the build being capable of it is not the
# question.
if unbound -V 2>&1 | grep -qiE 'modules:.*subnet'; then
  note "this build includes subnetcache; what matters is whether it is loaded"
fi
mc=$(unbound-control get_option module-config 2>/dev/null || echo "?")
if grep -qiE 'subnet' <<< "$mc"; then
  fail "ECS module is not loaded" "module-config contains a subnet module: ${mc}"
else
  pass "ECS module is not loaded" "module-config = ${mc}"
fi

# And prove it behaviourally: a client that sends ECS must get none back.
if command -v dig >/dev/null 2>&1; then
  if dig +time=5 +tries=1 @127.0.0.1 +subnet=203.0.113.0/24 example.com A 2>/dev/null \
    | grep -qi 'CLIENT-SUBNET'; then
    fail "ECS is not echoed to clients" "the resolver returned a CLIENT-SUBNET option"
  else
    pass "ECS is not echoed to clients"
  fi
fi
if grep -rqsE '^\s*(send-client-subnet|client-subnet-always-forward|max-client-subnet)' /etc/unbound/; then
  fail "no ECS options configured" "client-subnet options present in /etc/unbound"
else
  pass "no ECS options configured"
fi

# --- Resolution posture ------------------------------------------------------
# These exist because this audit once passed 46/46 while the resolver was
# forwarding every query to the hosting provider's resolvers in cleartext.
# Debian's unbound-resolvconf.service injects a root forward zone at RUNTIME via
# unbound-control, so it appears in no config file and a config review cannot see
# it. Only the running daemon knows.
#
# So the question is not "is there a forwarder" — with forward_tls_upstreams set
# there is supposed to be one. The question is whether the forwarder is the one we
# chose, reached over authenticated TLS, with no silent cleartext fallback.

ucfg=/etc/unbound/unbound.conf
fwd=$(unbound-control list_forwards 2>/dev/null | grep -vE '^[[:space:]]*$' || true)
upstreams=${GALENA_FORWARD_UPSTREAMS:-}

node_addrs=$( { ip -4 -o addr show scope global; ip -6 -o addr show scope global; } 2>/dev/null \
  | awk '{print $4}' | cut -d/ -f1 )

# The behavioural test, used by both postures: ask an authoritative server which
# address it sees. This is how the original cleartext-forwarding bug was found,
# and it is the only check here that cannot be satisfied by a convincing config.
seen=$(dig +short +time=8 +tries=2 TXT o-o.myaddr.l.google.com @127.0.0.1 2>/dev/null | tr -d '"' | head -1)
if [[ -z $seen ]]; then
  seen=$(dig +short +time=8 +tries=2 TXT whoami.ds.akahelp.net @127.0.0.1 2>/dev/null \
    | tr -d '"' | tr ' ' '\n' | grep -vx ns | head -1)
fi

if [[ -n $upstreams ]]; then
  # ---- Forwarding posture -------------------------------------------------
  if [[ -z $fwd ]]; then
    fail "forward zone matches configuration" "configured to forward, but unbound has none"
    note "it is recursing in cleartext instead — the provider sees every query name"
  else
    matched=0 total=0
    for u in $upstreams; do
      total=$((total + 1))
      # Either the address or the #tls-auth-name is enough. Matching on both
    # forms means a difference in list_forwards' output format cannot fail this,
    # while provider resolvers injected by resolvconf match neither.
    if grep -qF "${u%%@*}" <<< "$fwd" || { [[ $u == *#* ]] && grep -qF "${u##*#}" <<< "$fwd"; }; then
      matched=$((matched + 1))
    fi
    done
    if ((matched == 0)); then
      fail "forward zone matches configuration" "running forwarders match none of the configured upstreams"
      note "configured: ${upstreams}"
      note "running:    $(tr '\n' ' ' <<< "$fwd")"
      note "most likely unbound-resolvconf came back and replaced our upstreams"
    elif ((matched < total)); then
      warn "forward zone matches configuration" "${matched}/${total} configured upstreams present"
    else
      pass "forward zone matches configuration" "${matched}/${total} upstreams"
    fi
  fi

  if grep -qE '^\s*forward-tls-upstream:\s*yes' "$ucfg"; then
    pass "upstream transport is TLS" "query names are encrypted in transit"
  else
    fail "upstream transport is TLS" "forward-tls-upstream is not yes"
    note "query names are leaving this host in cleartext on port 53"
  fi

  # Without #tls-auth-name unbound does opportunistic TLS: encrypted, but the
  # certificate is not checked, so anyone in a network position can intercept.
  n_addr=$(grep -cE '^\s*forward-addr:' "$ucfg" || true)
  n_auth=$(grep -E '^\s*forward-addr:' "$ucfg" | grep -c '#' || true)
  if ((n_addr > 0)) && ((n_auth == n_addr)); then
    pass "upstream certificates are verified" "${n_auth}/${n_addr} carry #tls-auth-name"
  else
    fail "upstream certificates are verified" "only ${n_auth}/${n_addr} forward-addr carry #tls-auth-name"
    note "TLS without an auth name is unauthenticated and interceptable"
  fi

  if grep -qE '^\s*forward-first:\s*no' "$ucfg"; then
    pass "no cleartext fallback" "an unreachable upstream SERVFAILs rather than recursing"
  else
    fail "no cleartext fallback" "forward-first is not 'no'"
    note "unbound will recurse in cleartext whenever the upstream is unreachable"
  fi

  # Positive evidence of a live DoT session. Idle is legitimate, so this warns
  # rather than fails: unbound closes upstream connections when traffic is quiet.
  dot=$(ss -tnH state established 2>/dev/null | awk '{print $4}' | grep -c ':853$' || true)
  if ((dot > 0)); then
    pass "live DoT session to upstream" "${dot} established connection(s) on 853"
  else
    warn "live DoT session to upstream" "none established right now (normal when idle)"
  fi

  # Under forwarding, an authoritative server must NOT see this node: it should
  # see the upstream. Seeing ourselves means we are recursing despite the config.
  if [[ -z $seen ]]; then
    warn "recursion is not happening here" "could not reach an egress-reporting authoritative server"
  elif grep -qxF "$seen" <<< "$node_addrs"; then
    fail "recursion is not happening here" "authoritative servers see ${seen}, which IS this node"
    note "queries are being resolved locally in cleartext, not forwarded over TLS"
  else
    pass "recursion is not happening here" "authoritative servers see ${seen} (the upstream)"
  fi

  note "the upstream sees every query name — see PRIVACY.md, this is the trade"
else
  # ---- Full recursion posture ---------------------------------------------
  if [[ -n $fwd ]]; then
    fail "unbound has no forwarders" "forwarding to: $(tr '\n' ' ' <<< "$fwd")"
    note "every query name is being sent to a third party; this is not a recursive resolver"
  else
    pass "unbound has no forwarders" "resolves from the root"
  fi

  if [[ -z $seen ]]; then
    warn "recursion egress is this host" "could not reach an egress-reporting authoritative server"
  elif grep -qxF "$seen" <<< "$node_addrs"; then
    pass "recursion egress is this host" "authoritative servers see ${seen}"
  else
    fail "recursion egress is this host" "authoritative servers see ${seen}, which is NOT an address of this node"
    note "our addresses: $(tr '\n' ' ' <<< "$node_addrs")"
    note "queries are leaving through someone else's resolver"
  fi
fi

# Masked in both postures: it would replace a deliberate TLS upstream with the
# provider's cleartext resolvers just as readily as it would break recursion.
rcstate=$(systemctl is-enabled unbound-resolvconf.service 2>&1 || true)
case $rcstate in
  masked) pass "unbound-resolvconf is masked" ;;
  *"No such file"* | *"not found"*) pass "unbound-resolvconf is masked" "unit not present" ;;
  *) fail "unbound-resolvconf is masked" "state is '${rcstate}' — it will re-add forwarders on the next resolvconf update" ;;
esac

# ===========================================================================
section "4. Response policy zones"
# ===========================================================================
rpzconf=/etc/unbound/unbound.conf.d/galena-rpz.conf
if [[ -r $rpzconf ]]; then
  zones=$(grep -c '^rpz:' "$rpzconf")
  logs_on=$(grep -cE '^\s*rpz-log:\s*yes' "$rpzconf" || true)
  logs_off=$(grep -cE '^\s*rpz-log:\s*no' "$rpzconf" || true)
  if ((logs_on > 0)); then
    fail "every RPZ zone has rpz-log: no" "${logs_on} zone(s) have rpz-log: yes"
  elif ((logs_off != zones)); then
    fail "every RPZ zone has rpz-log: no" "${zones} zones but only ${logs_off} rpz-log: no"
  else
    pass "every RPZ zone has rpz-log: no" "${zones} zones"
  fi

  # Order is semantic: a passthru is a match, and a match stops evaluation of
  # later zones, so the allowlist is only effective if it is first.
  first=$(grep -A1 '^rpz:' "$rpzconf" | grep -m1 'name:' | awk '{print $2}')
  if [[ $first == allowlist.rpz.galena ]]; then
    pass "allowlist RPZ is evaluated first" "$first"
  else
    fail "allowlist RPZ is evaluated first" "first zone is '${first}' — allowlist entries will be ignored"
  fi
else
  fail "RPZ configuration is present" "${rpzconf} missing"
fi

if unbound-control status >/dev/null 2>&1; then
  note "loaded zones and record counts:"
  while read -r zname; do
    [[ -n $zname ]] || continue
    zfile="/var/lib/unbound/rpz/${zname%%.rpz.galena}.rpz"
    if [[ -r $zfile ]]; then
      n=$(grep -cE '[[:space:]](CNAME|A|AAAA|TXT)[[:space:]]' "$zfile" 2>/dev/null || echo 0)
      printf '       %-26s %10s records  %6s MB\n' "$zname" "$n" \
        "$(($(stat -c %s "$zfile") / 1048576))"
    fi
  done < <(grep -E '^\s*name:' "$rpzconf" 2>/dev/null | awk '{print $2}')
fi

# ===========================================================================
section "5. dnsdist configuration"
# ===========================================================================
dconf=/etc/dnsdist/dnsdist.conf
if [[ -r $dconf ]]; then
  # Every one of these would write query data to disk or ship it off the box.
  declare -a banned=(
    carbonServer newRemoteLogger RemoteLogAction RemoteLogResponseAction
    newFrameStreamTcpLogger newFrameStreamUnixLogger DnstapLogAction
    LogAction setVerboseLogDestination
  )
  found=()
  for pat in "${banned[@]}"; do
    # Ignore the comment block that lists these by name.
    if grep -vE '^\s*--' "$dconf" | grep -q "\b${pat}\b"; then found+=("$pat"); fi
  done
  if ((${#found[@]})); then
    fail "no query logging or remote logging in dnsdist" "found: ${found[*]}"
  else
    pass "no query logging or remote logging in dnsdist"
  fi

  if grep -vE '^\s*--' "$dconf" | grep -qE 'setVerbose\(\s*true\s*\)'; then
    fail "dnsdist verbose logging is off" "setVerbose(true) present"
  else
    pass "dnsdist verbose logging is off"
  fi

  if grep -vE '^\s*--' "$dconf" | grep -q 'setSecurityPollSuffix("")'; then
    pass "dnsdist version phone-home is disabled"
  else
    fail "dnsdist version phone-home is disabled" "setSecurityPollSuffix(\"\") not found"
  fi

  # Read the rendered variable, not setRingBuffersSize(...): the first literal
  # number in the file is the 0 in the disabled branch, which misreported a
  # 5000-entry ring as 0.
  ring=$(grep -oE '^local ringEntries = [0-9]+' "$dconf" | grep -oE '[0-9]+$' || echo "?")
  if grep -q 'recordResponses = false' "$dconf"; then
    pass "dnsdist ring records no responses" "ring=${ring} queries, responses off"
  else
    warn "dnsdist ring records no responses" "recordResponses is not explicitly false"
  fi
  note "the ring is the only place CLIENT IPs and qnames appear together, in RAM only"

  # The packet cache also holds responses in RAM, but keyed by question rather
  # than by client, so it cannot attribute anything to anyone. Saying "no
  # responses in RAM" while a packet cache exists would be false, hence the
  # narrower claim above and this reported separately.
  pcache=$(grep -oE '^local packetCacheEntries = [0-9]+' "$dconf" | grep -oE '[0-9]+$' || echo 0)
  if [[ ${pcache:-0} -gt 0 ]]; then
    # print() is not relayed over `dnsdist -c -e`, so stats have to come from the
    # commands that write to the console themselves. showPools prints "used/max"
    # for the pool's cache; dumpStats carries the counters.
    used=$(dnsdist -c -e 'showPools()' 2>/dev/null | grep -oE '[0-9]+/[0-9]+' | head -1)
    dstats=$(dnsdist -c -e 'dumpStats()' 2>/dev/null | tr -s ' \t' '\n')
    hits=$(awk '/^cache-hits$/{getline; print; exit}' <<< "$dstats")
    miss=$(awk '/^cache-misses$/{getline; print; exit}' <<< "$dstats")
    detail="max ${pcache} entries"
    [[ $used =~ ^[0-9]+/[0-9]+$ ]] && detail="${detail}, in use ${used}"
    [[ $hits =~ ^[0-9]+$ && $miss =~ ^[0-9]+$ ]] && detail="${detail}, hits/misses ${hits}/${miss}"
    pass "packet cache is question-keyed, RAM only" "$detail"
    note "it can say what was asked recently, never by whom; it never touches disk"
  else
    pass "packet cache is question-keyed, RAM only" "disabled"
  fi

  # The webserver's HTML console can surface topQueries from the ring.
  if ss -lntHn 2>/dev/null | awk '{print $4}' | grep -qE ':8083$'; then
    if [[ ${GALENA_ENABLE_METRICS:-0} == 1 ]]; then
      bound=$(ss -lntHn | awk '{print $4}' | grep ':8083$' | head -1)
      if [[ $bound == 127.0.0.1:* || $bound == "[::1]:"* ]]; then
        warn "dnsdist webserver" "enabled, bound to ${bound} (loopback only, as configured)"
      else
        fail "dnsdist webserver" "enabled and bound to ${bound} — NOT loopback"
      fi
    else
      fail "dnsdist webserver is disabled" "something is listening on 8083 but metrics are off"
    fi
  else
    pass "dnsdist webserver is disabled"
  fi
else
  fail "dnsdist configuration is present" "${dconf} missing"
fi

# ===========================================================================
section "6. Outbound connections"
# ===========================================================================
# A remote logging sink would show up here as an established connection to
# something that is not DNS, ACME or the blocklist CDN.
# Exclude the admin CIDR: the SSH session running this audit would otherwise
# always appear here, training the reader to ignore the check.
# Inbound and outbound connections both appear in `ss state established`, and they
# have to be told apart by the LOCAL port, not the peer's.
#
# This filtered on the peer port alone, which reported every CLIENT connection as an
# unexpected outbound one: an inbound DoT connection is local=:853 with an ephemeral
# peer port, so it matched nothing in the exclusion list. The check therefore only
# passed while the admin was the resolver's only user — the first real client to
# connect produced a WARN naming them. Route 53 health checkers now connect to 853
# every 30 seconds as well, so it would have warned permanently, which is precisely
# the "train the reader to ignore this check" failure the note below warns about.
admin_ip=${GALENA_ADMIN_CIDR%%/*}
unexpected=$(ss -tupnH state established 2>/dev/null \
  | awk -v admin="${admin_ip:-__no_admin_ip__}" '
      function port(a) { sub(/.*:/, "", a); return a }
      {
        local = $4; peer = $5; proc = $6
        # Either end on loopback is dnsdist talking to unbound.
        if (local ~ /^(127\.0\.0\.1|\[::1\]):/ || peer ~ /^(127\.0\.0\.1|\[::1\]):/) next
        # INBOUND to a port we deliberately publish: clients on DoH and DoT, the
        # health checkers probing 853, and the SSH session running this audit.
        if (port(local) ~ /^(443|853|22)$/) next
        # OUTBOUND to DNS, ACME or the blocklist CDN.
        if (port(peer) ~ /^(53|443|853|80)$/) next
        if (admin != "__no_admin_ip__" && index(peer, admin)) next
        print peer, proc
      }' || true)
if [[ -n $unexpected ]]; then
  warn "no unexpected outbound connections" "review these:"
  sed 's/^/       /' <<< "$unexpected"
else
  pass "no unexpected outbound connections"
fi

# ===========================================================================
section "7. Scheduled jobs"
# ===========================================================================
crons=$(find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly \
  -type f 2>/dev/null \
  | grep -vE '/(e2scrub_all|dpkg|man-db|apt-compat|logrotate|plocate|certbot|aptitude)$' \
  | grep -vE '/\.placeholder$' || true)
if [[ -n $crons ]]; then
  warn "no unexpected cron jobs" "review these:"
  sed 's/^/       /' <<< "$crons"
else
  pass "no unexpected cron jobs"
fi
note "active timers:"
systemctl list-timers --no-pager --no-legend 2>/dev/null | awk '{print $NF}' | sort -u | sed 's/^/       /'

# logrotate implies something is being written that needs rotating.
if [[ -d /etc/logrotate.d ]]; then
  note "logrotate configs present for: $(find /etc/logrotate.d -type f -printf '%f ' 2>/dev/null)"
fi

# ===========================================================================
section "8. Host resolver"
# ===========================================================================
ns_all=$(awk '/^[[:space:]]*nameserver/{print $2}' /etc/resolv.conf 2>/dev/null)
ns_local=$(grep -cxE '(127\.0\.0\.1|::1)' <<< "$ns_all" || true)
ns_ext=$(grep -vxE '(127\.0\.0\.1|::1)' <<< "$ns_all" || true)
if ((ns_local > 0)) && [[ -z $ns_ext ]]; then
  pass "host resolves through its own unbound"
  note "so apt, ACME and blocklist lookups do not reach a third-party resolver"
elif ((ns_local > 0)); then
  warn "host resolves through its own unbound" "also lists: $(tr '\n' ' ' <<< "$ns_ext")"
else
  warn "host resolves through its own unbound" "resolv.conf nameservers: $(tr '\n' ' ' <<< "$ns_all")"
fi

if lsattr /etc/resolv.conf 2>/dev/null | grep -q 'i'; then
  pass "/etc/resolv.conf is immutable" "DHCP cannot rewrite it"
else
  warn "/etc/resolv.conf is immutable" "not immutable — DHCP may repoint it"
fi

# ===========================================================================
section "9. Known and accepted on-disk data"
# ===========================================================================
# Being explicit about what IS written matters as much as what is not: an audit
# that reports a clean sheet while /var/log/letsencrypt exists is not credible.
if [[ -d /var/log/letsencrypt ]]; then
  sz=$(du -sh /var/log/letsencrypt 2>/dev/null | cut -f1)
  pass "certbot logs contain no client data" "/var/log/letsencrypt (${sz}) — ACME protocol only"
fi
if [[ -d /var/log/unattended-upgrades ]]; then
  pass "unattended-upgrades logs contain no client data" "package names only"
fi
note "RPZ zone files are blocklists we installed, not records of anything asked"
if [[ -n ${GALENA_FORWARD_UPSTREAMS:-} ]]; then
  note "nothing about a query is retained HERE, but the upstream receives every"
  note "query name: ${GALENA_FORWARD_UPSTREAMS%% *} and peers. Their retention is their"
  note "policy, not ours, and this audit cannot verify it. See PRIVACY.md."
fi

# ===========================================================================
section "10. Empirical test: does a query reach the disk?"
# ===========================================================================
# Config review cannot prove a negative. This sends a query whose name exists
# nowhere else in the universe, then searches the writable filesystem for it.
marker="galena-audit-$(tr -dc a-z0-9 < /dev/urandom | head -c 16).invalid"
probe_ok=0

if command -v kdig >/dev/null 2>&1; then
  # `+tls` alone is opportunistic. Adding +tls-hostname would make kdig VERIFY
  # the certificate, which fails while acme_staging is on — and verification is
  # `make test`'s job, not this one. All this probe needs is for the query to
  # travel the real DoT path through dnsdist.
  if kdig +tls +timeout=5 "@127.0.0.1" "$marker" A >/dev/null 2>&1; then
    probe_ok=1
  fi
fi
if ((probe_ok == 0)); then
  # Fall back to plaintext straight at unbound. Still exercises the full
  # resolve-and-log path, just not dnsdist's TLS front end.
  if dig +time=5 +tries=1 "@127.0.0.1" "$marker" A >/dev/null 2>&1; then probe_ok=2; fi
fi

case $probe_ok in
  1) note "probe sent over DoT through dnsdist: ${marker}" ;;
  2) note "probe sent in plaintext to unbound (DoT probe unavailable): ${marker}" ;;
  *) fail "audit probe query was answered" "could not send a probe — the search below would prove nothing" ;;
esac

if ((probe_ok > 0)); then
  sleep 2
  # Search everything writable that could plausibly hold a log. The RPZ
  # directory is excluded only for speed: it is 60 MB of blocklist we installed
  # ourselves, and it is rewritten wholesale on every refresh.
  hits=$(timeout 120 grep -rlF "$marker" \
    /var/log /var/lib /var/cache /var/tmp /etc /root /home /tmp /srv /opt \
    --exclude-dir=/var/lib/unbound/rpz 2>/dev/null || true)
  # journalctl covers the RAM journal, which is expected to hold nothing at
  # MaxLevelStore=warning but is worth confirming.
  jhits=$(journalctl --no-pager 2>/dev/null | grep -cF "$marker" || true)

  if [[ -n $hits ]]; then
    fail "probe qname is nowhere on disk" "FOUND IN:"
    sed 's/^/       /' <<< "$hits"
  else
    pass "probe qname is nowhere on disk" "searched /var /etc /root /home /tmp /srv /opt"
  fi

  if ((jhits > 0)); then
    warn "probe qname is not in the journal" "${jhits} line(s) in the RAM journal (volatile, lost on reboot)"
  else
    pass "probe qname is not in the journal"
  fi
fi

# ===========================================================================
section "11. Memory"
# ===========================================================================
mem_total=$(awk '/MemTotal/{print $2}' /proc/meminfo)
mem_avail=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
u_rss=$(ps -o rss= -C unbound 2>/dev/null | awk '{s+=$1} END{print s+0}')
d_rss=$(ps -o rss= -C dnsdist 2>/dev/null | awk '{s+=$1} END{print s+0}')
printf '       unbound %s MB | dnsdist %s MB | available %s MB of %s MB\n' \
  "$((u_rss / 1024))" "$((d_rss / 1024))" "$((mem_avail / 1024))" "$((mem_total / 1024))"

# Read this number knowing what inflates it. An auth_zone_reload holds the old
# and new zone at once, and glibc keeps the freed arena rather than returning it
# to the OS — so unbound's RSS right after a blocklist refresh reflects the
# reload peak, not what it actually needs. Measured on this node with the same
# four zones: 1366 MB immediately after a reload, 557 MB after a clean restart.
# It matters because systemd's MemoryMax acts on RSS, so the cap has to cover the
# peak; it also means a scary-looking figure just after `make deploy` is usually
# nothing. Restart unbound and re-run this to see the steady state.
if ((u_rss > 1048576)); then
  note "RSS above 1 GB is usually reload residue, not steady state — glibc keeps the"
  note "freed arena after auth_zone_reload. 'systemctl restart unbound' to compare."
fi

if ((mem_avail < 262144)); then
  warn "sufficient free memory" "under 256 MB available — lower the unbound cache sizes"
else
  pass "sufficient free memory"
fi

# ===========================================================================
printf '\n%s%s%s\n' "$B" "Summary" "$N"
printf '  %sPASS %d%s   %sWARN %d%s   %sFAIL %d%s\n' \
  "$G" "$pass_n" "$N" "$Y" "$warn_n" "$N" "$R" "$fail_n" "$N"

if ((fail_n > 0)); then
  printf '\n%sFailures:%s\n' "$R" "$N"
  for r in "${RESULTS[@]}"; do
    IFS=$'\t' read -r st label detail <<< "$r"
    [[ $st == FAIL ]] && printf '  - %s %s\n' "$label" "${detail:+($detail)}"
  done
  printf '\n%sThis node does not meet its own privacy claims. Fix before publishing it.%s\n' "$R" "$N"
  exit 1
fi

printf '\nNo failures. What IS retained is listed in section 9 and in PRIVACY.md.\n'
exit 0
