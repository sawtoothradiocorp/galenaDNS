#!/usr/bin/env bash
#
# galena-dns — verify a deployed resolver from your own machine.
#
# Tool coverage, and why it takes two of them:
#
#   kdig       DoT, DoH (HTTP/2), DoQ      brew install knot
#   dnslookup  DoH3 (HTTP/3)               brew install ameshkov/tap/dnslookup
#
# kdig cannot do DoH3: its +https is built on libnghttp2, which is HTTP/2 only.
# dig cannot do QUIC at all. So DoH3 needs a third tool, and it is skipped with a
# warning rather than silently passing if dnslookup is not installed.
#
# Certificate verification is real here: kdig uses +tls-ca, which validates the
# chain against the system trust store and fails the handshake on a wrong name.

set -uo pipefail

DOMAIN=""
IP=""
INCLUDE_RATELIMIT=0
INSECURE=0
DOH_PATH="/dns-query"
declare -a FEEDS=()

# Fixtures verified live on 2026-09-25. See README for how each was checked.
BLOCKED_AD="scorecardresearch.com"    # present in Hagezi Pro
# The allowlisted domain is read from the zone file rather than hardcoded, so this
# test tracks whatever you actually allow instead of a fixture that may be gone.
ALLOWLIST_FILE=""
DNSSEC_BAD="sigfail.verteiltesysteme.net"
DNSSEC_BAD_ALT="dnssec-failed.org"
DNSSEC_OK="sigok.verteiltesysteme.net"
CONTROL="example.com"

usage() {
  cat <<EOF
Usage: $0 --domain <fqdn> [--ip <addr>] [options]

  --domain FQDN         Public hostname of the resolver (must match its cert)
  --ip ADDR             Connect to this address instead of resolving DOMAIN.
                        Use it to test one specific node behind round-robin.
  --feed URL            Blocklist feed to sample malware fixtures from.
                        Repeatable. Defaults to Hagezi TIF medium.
  --allowlist FILE      Allowlist RPZ zone to read a test domain from.
                        Defaults to node/unbound/rpz/allowlist.rpz.
  --include-ratelimit   Also test rate limiting. This will get your address
                        dynamically blocked for the configured duration.
  --insecure            Skip certificate validation (for acme_staging = true).
  -h, --help            This.
EOF
}

while (($#)); do
  case $1 in
    --domain) DOMAIN=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --feed) FEEDS+=("$2"); shift 2 ;;
    --doh-path) DOH_PATH=$2; shift 2 ;;
    --allowlist) ALLOWLIST_FILE=$2; shift 2 ;;
    --include-ratelimit) INCLUDE_RATELIMIT=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n $DOMAIN ]] || {
  echo "--domain is required" >&2
  exit 2
}
((${#FEEDS[@]})) || FEEDS=("https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/tif.medium.txt")
if [[ -z $ALLOWLIST_FILE ]]; then
  ALLOWLIST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/node/unbound/rpz/allowlist.rpz"
fi

TARGET="${IP:-$DOMAIN}"

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=''; G=''; Y=''; R=''; D=''; N=''
fi

pass_n=0 fail_n=0 skip_n=0
declare -a FAILED=()

pass() {
  printf '  %sPASS%s %-50s %s\n' "$G" "$N" "$1" "${2:-}"
  ((pass_n++))
}
fail() {
  printf '  %sFAIL%s %-50s %s\n' "$R" "$N" "$1" "${2:-}"
  FAILED+=("$1${2:+ — $2}")
  ((fail_n++))
}
skip() {
  printf '  %sSKIP%s %-50s %s\n' "$Y" "$N" "$1" "${2:-}"
  ((skip_n++))
}
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

have() { command -v "$1" >/dev/null 2>&1; }

# kdig and dnslookup both print a dig-style header, but kdig separates fields
# with ';' and dnslookup with ',' — so match the token, not the punctuation.
rcode_of() { grep -oE 'status: [A-Z]+' <<< "$1" | head -1 | awk '{print $2}'; }

# kdig's +tls-hostname does not merely set a name — it turns on certificate
# AUTHENTICATION, and it does so even alongside plain +tls. So --insecure has to
# drop it entirely and keep only +tls-sni, which selects the certificate without
# demanding it verify. Getting this wrong made --insecure silently do nothing.
tls_args() {
  if ((INSECURE)); then
    printf '%s\n' "+tls" "+tls-sni=${DOMAIN}"
  else
    printf '%s\n' "+tls-ca" "+tls-hostname=${DOMAIN}" "+tls-sni=${DOMAIN}"
  fi
}

# --- transports ------------------------------------------------------------

q_dot() {
  local ta; IFS=$'\n' read -r -d '' -a ta < <(tls_args; printf '\0')
  kdig "${ta[@]}" +timeout=6 +retry=1 "@${TARGET}" "$1" "${2:-A}" 2>&1
}
q_doh() {
  local ta; IFS=$'\n' read -r -d '' -a ta < <(tls_args; printf '\0')
  kdig "${ta[@]}" "+https=${DOH_PATH}" +timeout=6 +retry=1 "@${TARGET}" "$1" "${2:-A}" 2>&1
}
q_doq() {
  local ta; IFS=$'\n' read -r -d '' -a ta < <(tls_args; printf '\0')
  kdig "${ta[@]}" +quic +timeout=6 +retry=1 "@${TARGET}" "$1" "${2:-A}" 2>&1
}
q_doh3() {
  # dnslookup takes a URL, so it resolves the host itself rather than accepting
  # a separate target. In insecure mode aim it at $TARGET — which may be the IP —
  # so the test does not depend on the control machine's own DNS being able to
  # resolve the name. In verifying mode the hostname is required, because that is
  # what the certificate is issued for.
  if ((INSECURE)); then
    VERIFY=0 dnslookup "$1" "h3://${TARGET}${DOH_PATH}" 2>&1
  else
    dnslookup "$1" "h3://${DOMAIN}${DOH_PATH}" 2>&1
  fi
}

printf '%sgalena-dns resolver test%s\n' "$B" "$N"
printf '  domain %s   target %s   cert validation %s\n' \
  "$DOMAIN" "$TARGET" "$( ((INSECURE)) && echo OFF || echo ON)"

# ===========================================================================
section "Tooling"
# ===========================================================================
if have kdig; then
  pass "kdig present" "$(kdig --version 2>&1 | head -1)"
else
  fail "kdig present" "brew install knot — DoT, DoH and DoQ cannot be tested without it"
fi
if have dnslookup; then
  pass "dnslookup present" "needed for DoH3"
else
  skip "dnslookup present" "brew install ameshkov/tap/dnslookup — DoH3 will be skipped"
fi

# ===========================================================================
section "Transports"
# ===========================================================================
if have kdig; then
  for spec in "DoT:q_dot" "DoH (HTTP/2):q_doh" "DoQ:q_doq"; do
    label=${spec%%:*}
    fn=${spec##*:}
    out=$($fn "$CONTROL")
    rc=$(rcode_of "$out")
    if [[ $rc == NOERROR ]]; then
      proof=$(grep -oE ';; (HTTP|QUIC) session[^)]*\)' <<< "$out" | head -1)
      [[ -n $proof ]] || proof=$(grep -oE ';; TLS session[^)]*\)' <<< "$out" | head -1)
      pass "${label} resolves ${CONTROL}" "${proof:-NOERROR}"
    else
      fail "${label} resolves ${CONTROL}" "${rc:-no response}: $(grep -iE 'error|warning' <<< "$out" | head -1)"
    fi
  done
else
  skip "DoT / DoH / DoQ" "kdig missing"
fi

if have dnslookup; then
  out=$(q_doh3 "$CONTROL")
  rc=$(rcode_of "$out")
  if [[ $rc == NOERROR ]]; then
    pass "DoH3 (HTTP/3) resolves ${CONTROL}" "via h3://"
  else
    fail "DoH3 (HTTP/3) resolves ${CONTROL}" "${rc:-no response}: $(grep -iE 'error' <<< "$out" | head -1)"
  fi
else
  skip "DoH3 (HTTP/3)" "dnslookup missing (kdig cannot do HTTP/3)"
fi

# ===========================================================================
section "DNSSEC validation"
# ===========================================================================
if have kdig; then
  bogus_caught=0
  for bad in "$DNSSEC_BAD" "$DNSSEC_BAD_ALT"; do
    rc=$(rcode_of "$(q_dot "$bad")")
    if [[ $rc == SERVFAIL ]]; then
      pass "bogus signature is rejected" "${bad} -> SERVFAIL"
      bogus_caught=1
    else
      fail "bogus signature is rejected" "${bad} -> ${rc:-no response}, expected SERVFAIL"
    fi
  done
  ((bogus_caught)) || fail "DNSSEC validation is enabled" "no bogus-signature domain was rejected"

  ta_ad=(); IFS=$'\n' read -r -d '' -a ta_ad < <(tls_args; printf '\0')
  out=$(kdig "${ta_ad[@]}" +dnssec +timeout=6 +retry=1 "@${TARGET}" "$DNSSEC_OK" A 2>&1)
  rc=$(rcode_of "$out")
  # The AD bit is the resolver telling us it validated, rather than just not failing.
  if [[ $rc == NOERROR ]] && grep -qE '^;; Flags:.*\bad\b' <<< "$out"; then
    pass "valid signature sets the AD flag" "${DNSSEC_OK}"
  elif [[ $rc == NOERROR ]]; then
    fail "valid signature sets the AD flag" "NOERROR but no AD bit — validation may be off"
  else
    fail "valid signature sets the AD flag" "${DNSSEC_OK} -> ${rc:-no response}"
  fi
else
  skip "DNSSEC checks" "kdig missing"
fi

# ===========================================================================
section "Blocking"
# ===========================================================================
if have kdig; then
  # RPZ `CNAME .` is the NXDOMAIN action.
  rc=$(rcode_of "$(q_dot "$BLOCKED_AD")")
  if [[ $rc == NXDOMAIN ]]; then
    pass "ad/tracker domain is blocked" "${BLOCKED_AD} -> NXDOMAIN"
  else
    fail "ad/tracker domain is blocked" "${BLOCKED_AD} -> ${rc:-no response}, expected NXDOMAIN"
  fi

  # Malware fixtures are sampled from the live feed rather than hardcoded:
  # individual malware domains get delisted within weeks, so a pinned one turns
  # into a scheduled false failure. A 128 KiB range yields a few thousand entries.
  for feed in "${FEEDS[@]}"; do
    feed_name=${feed##*/}
    head_bytes=$(curl -fsSL --max-time 45 -r 0-131072 "$feed" 2>/dev/null || true)
    if [[ -z $head_bytes ]]; then
      skip "sampled domains blocked (${feed_name})" "could not fetch a sample of the feed"
      continue
    fi
    # A response-IP feed triggers on the ANSWER address, not the query name, so
    # there is nothing here a domain lookup could test. `make audit` confirms the
    # zone is loaded; the README shows how to verify one entry by hand.
    if grep -qE '\.rpz-ip[[:space:]]' <<< "$head_bytes"; then
      skip "sampled domains blocked (${feed_name})" "response-IP feed — not testable by domain lookup"
      continue
    fi
    sample=$(grep -oE '^[a-z0-9][a-z0-9.-]+\.[a-z]{2,} CNAME \.$' <<< "$head_bytes" \
      | awk '{print $1}' | sort -u | sort -R | head -3)
    if [[ -z $sample ]]; then
      skip "sampled domains blocked (${feed_name})" "no parsable entries in the sampled range"
      continue
    fi
    n_ok=0 n_tot=0
    while read -r d; do
      [[ -n $d ]] || continue
      n_tot=$((n_tot + 1))
      [[ $(rcode_of "$(q_dot "$d")") == NXDOMAIN ]] && n_ok=$((n_ok + 1))
    done <<< "$sample"
    if ((n_ok == n_tot && n_tot > 0)); then
      pass "sampled domains blocked (${feed_name})" "${n_ok}/${n_tot} -> NXDOMAIN"
    else
      fail "sampled domains blocked (${feed_name})" "only ${n_ok}/${n_tot} returned NXDOMAIN"
    fi
  done

  # Read a testable entry out of the allowlist zone. Wildcards and rpz-ip
  # triggers are skipped deliberately: querying a made-up label under a wildcard
  # usually returns a genuine upstream NXDOMAIN, which looks exactly like the
  # allowlist failing and would be a false alarm.
  if [[ ! -r $ALLOWLIST_FILE ]]; then
    skip "allowlisted domain passes" "no allowlist zone at ${ALLOWLIST_FILE}"
  else
    ALLOWED=$(grep -oE '^[a-z0-9][a-z0-9.-]*[[:space:]]+CNAME[[:space:]]+rpz-passthru\.$' "$ALLOWLIST_FILE" \
      | awk '{print $1}' | grep -v 'rpz-ip$' | head -1)
    if [[ -z $ALLOWED ]]; then
      skip "allowlisted domain passes" "allowlist has no plain-domain entries to test"
      printf '       %sZone order is still checked structurally by `make audit` (section 4).%s\n' "$D" "$N"
    else
      rc=$(rcode_of "$(q_dot "$ALLOWED")")
      if [[ $rc == NOERROR ]]; then
        pass "allowlisted domain passes" "${ALLOWED} -> NOERROR"
        printf '       %sProves passthru precedence only if %s is also on a blocklist.%s\n' "$D" "$ALLOWED" "$N"
      elif [[ $rc == NXDOMAIN ]]; then
        fail "allowlisted domain passes" "${ALLOWED} -> NXDOMAIN; allowlist is not winning (zone order?)"
      else
        fail "allowlisted domain passes" "${ALLOWED} -> ${rc:-no response}"
      fi
    fi
  fi
else
  skip "blocking checks" "kdig missing"
fi

# ===========================================================================
section "Port 53 closed from outside"
# ===========================================================================
# dig bounds its own timeout, which nc does not do reliably against a filtered
# port — nc -z will sit there forever.
if [[ -n $IP ]]; then
  probe_ip=$IP
else
  probe_ip=$(dig +short "$DOMAIN" A 2>/dev/null | head -1)
fi

if [[ -z $probe_ip ]]; then
  skip "port 53 is closed" "could not determine an address to probe"
else
  closed=1
  for extra in "" "+tcp"; do
    # shellcheck disable=SC2086
    if dig @"$probe_ip" $extra +timeout=3 +tries=1 "$CONTROL" A 2>/dev/null | grep -q 'status: NOERROR'; then
      closed=0
      fail "port 53 is closed ($( [[ -z $extra ]] && echo UDP || echo TCP ))" \
        "${probe_ip} answered a plaintext query — this is an open resolver"
    fi
  done
  if ((closed)); then
    # "It timed out" only means something if plain 53 works from here at all.
    # Prove the control path against a resolver known to answer on 53, so the
    # result is a conclusion rather than a hedge.
    if dig @1.1.1.1 +timeout=3 +tries=1 "$CONTROL" A 2>/dev/null | grep -q 'status: NOERROR'; then
      pass "port 53 is closed (UDP and TCP)" "${probe_ip} did not answer; outbound 53 verified working from here"
    else
      pass "port 53 is closed (UDP and TCP)" "${probe_ip} did not answer"
      printf '       %sPASS (weak): outbound 53 does not work from this network either,\n' "$D"
      printf '       so the timeout may be your network rather than the server.\n'
      printf '       Re-run from a network that permits plain DNS.%s\n' "$N"
    fi
  fi
fi

# ===========================================================================
section "Rate limiting"
# ===========================================================================
if ((INCLUDE_RATELIMIT == 0)); then
  skip "rate limiting" "opt in with --include-ratelimit (it will block your IP)"
elif ! have kdig; then
  skip "rate limiting" "kdig missing"
else
  printf '       %ssending a burst; if your address is in rate_limit_exempt_cidrs\n' "$D"
  printf '       (it defaults to admin_cidr) nothing will be dropped.%s\n' "$N"
  sent=0 answered=0
  for _ in $(seq 1 200); do
    sent=$((sent + 1))
    ta_b=(); IFS=$'\n' read -r -d '' -a ta_b < <(tls_args; printf '\0')
    if kdig "${ta_b[@]}" +timeout=2 +retry=0 "@${TARGET}" "burst-${RANDOM}.${CONTROL}" A 2>/dev/null \
      | grep -q 'status:'; then
      answered=$((answered + 1))
    fi
  done
  dropped=$((sent - answered))
  if ((dropped > 0)); then
    pass "rate limiting engages" "${dropped}/${sent} queries dropped"
  else
    fail "rate limiting engages" "all ${sent} queries answered — is your IP exempt, or the limit too high?"
  fi
fi

# ===========================================================================
printf '\n%sSummary%s  %sPASS %d%s  %sFAIL %d%s  %sSKIP %d%s\n' \
  "$B" "$N" "$G" "$pass_n" "$N" "$R" "$fail_n" "$N" "$Y" "$skip_n" "$N"

if ((fail_n)); then
  printf '\n%sFailures:%s\n' "$R" "$N"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
printf '\nResolver looks healthy.\n'
