#!/usr/bin/env bash
#
# galena-dns — refresh the RPZ blocklists.
#
# Why this exists instead of unbound's own `url:` fetch:
#
#   * A failed fetch at boot leaves the zone empty until the SOA refresh, with
#     no retry and nothing filtered in between.
#   * unbound's HTTP client does not follow CDN redirects.
#   * Most importantly, unbound will load whatever it is given. jsdelivr answers
#     an over-size request with `Package size exceeded the configured limit of
#     150 MB` as a 143-byte HTTP *200*. A naive fetcher installs that as your
#     blocklist and reports success. Hagezi's full rpz/tif.txt does exactly this.
#
# So: fetch, validate hard, swap atomically, reload, and roll back if the reload
# fails. Zones are processed one at a time to bound peak memory: a reload holds
# the old and new copy of a zone at once, and two of those peaks stacked is how a
# 4 GB node meets the OOM killer. This mattered most with the 1.75M-entry medium
# feed; the current zones are ~12 MB and smaller, but the rule costs nothing.
#
# Logs aggregate counts only. No domain ever reaches the log.

set -uo pipefail

RPZ_DIR=/var/lib/unbound/rpz
TMP_DIR="${RPZ_DIR}/.tmp"
MANIFEST=/opt/galena/rpz-manifest.tsv
# Must match the zone names bootstrap.sh writes into galena-rpz.conf.
ZONE_SUFFIX=".rpz.galena"

log() { printf '[rpz-update] %s\n' "$*"; }
err() { printf '[rpz-update] ERROR: %s\n' "$*" >&2; }

[[ -r $MANIFEST ]] || {
  err "manifest ${MANIFEST} not readable"
  exit 1
}

install -d -m 0755 -o unbound -g unbound "$RPZ_DIR" "$TMP_DIR"

unbound_up() { unbound-control status >/dev/null 2>&1; }

# Count policy records. Hagezi uses `CNAME .` throughout, including in the
# response-IP zone (`32.4.113.0.203.rpz-ip CNAME .`), but matching any record
# type keeps this working if a feed ever uses local-data actions instead.
count_records() { grep -cE '[[:space:]](CNAME|A|AAAA|TXT)[[:space:]]' "$1" 2>/dev/null || true; }

# Returns 0 if the downloaded file is a plausible RPZ zone.
validate() {
  local file=$1 min=$2 name=$3 count

  [[ -s $file ]] || {
    err "${name}: downloaded file is empty"
    return 1
  }

  # The CDN size-limit refusal, and HTML error pages generally, are short.
  if [[ $(stat -c %s "$file") -lt 1024 ]]; then
    err "${name}: only $(stat -c %s "$file") bytes — this is an error page, not a zone:"
    err "${name}: $(head -c 200 "$file" | tr -d '\n')"
    return 1
  fi

  if grep -qiE '^\s*(<!doctype|<html)' "$file"; then
    err "${name}: served HTML instead of a zone file"
    return 1
  fi

  if grep -qiF 'Package size exceeded' "$file"; then
    err "${name}: CDN refused the file for being over its size limit."
    err "${name}: pick a smaller feed variant, or use the mirror at hagezi-mirror.dnsbunker.org"
    return 1
  fi

  # A real RPZ zone starts with a TTL directive and has an SOA at the apex.
  if ! head -1 "$file" | grep -qE '^\$TTL'; then
    err "${name}: does not begin with a \$TTL directive"
    return 1
  fi

  if ! grep -qE '[[:space:]]SOA[[:space:]]' "$file"; then
    err "${name}: no SOA record — unbound will refuse to load this"
    return 1
  fi

  count=$(count_records "$file")
  if ((count < min)); then
    err "${name}: only ${count} records, expected at least ${min} — treating as truncated"
    return 1
  fi

  printf '%s' "$count"
  return 0
}

failed=0
updated=0
skipped=0

while IFS=$'\t' read -r name url min; do
  # Skip blanks and comments.
  [[ -n ${name:-} && $name != \#* ]] || continue
  [[ -n ${url:-} && -n ${min:-} ]] || {
    err "malformed manifest line for '${name}'"
    failed=1
    continue
  }

  dest="${RPZ_DIR}/${name}.rpz"
  prev="${RPZ_DIR}/${name}.rpz.prev"
  tmp="${TMP_DIR}/${name}.rpz.new"
  zone="${name}${ZONE_SUFFIX}"

  # Conditional GET: if the feed has not changed since our copy, the CDN answers
  # 304 and we move on without transferring the whole feed again.
  curl_args=(
    --fail --location --silent --show-error --compressed
    --retry 3 --retry-delay 5 --retry-connrefused
    --max-time 600 --connect-timeout 20
    --user-agent "galena-dns rpz-update"
    --output "$tmp"
    --write-out '%{http_code}'
  )
  [[ -s $dest ]] && curl_args+=(--time-cond "$dest")

  code=$(curl "${curl_args[@]}" "$url" 2>/dev/null)
  rc=$?

  if ((rc != 0)); then
    err "${name}: download failed (curl exit ${rc}, http ${code:-none}); keeping existing zone"
    failed=1
    rm -f "$tmp"
    continue
  fi

  if [[ $code == 304 ]] || [[ ! -s $tmp ]]; then
    log "${name}: unchanged since last fetch ($(count_records "$dest") records)"
    skipped=$((skipped + 1))
    rm -f "$tmp"
    continue
  fi

  if ! count=$(validate "$tmp" "$min" "$name"); then
    err "${name}: validation failed; keeping the existing zone"
    failed=1
    rm -f "$tmp"
    continue
  fi

  # Swap. The old file is kept so a failed reload can be undone.
  [[ -s $dest ]] && cp -f "$dest" "$prev"
  chown unbound:unbound "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$dest"

  if ! unbound_up; then
    log "${name}: installed ${count} records (unbound not running; it will load at start)"
    updated=$((updated + 1))
    continue
  fi

  if unbound-control auth_zone_reload "$zone" >/dev/null 2>&1; then
    log "${name}: loaded ${count} records"
    updated=$((updated + 1))
  else
    err "${name}: unbound refused to load the new zone; rolling back"
    if [[ -s $prev ]]; then
      mv -f "$prev" "$dest"
      if unbound-control auth_zone_reload "$zone" >/dev/null 2>&1; then
        err "${name}: rolled back to the previous zone successfully"
      else
        err "${name}: ROLLBACK ALSO FAILED — zone ${zone} may now be empty"
      fi
    else
      err "${name}: no previous copy to roll back to"
    fi
    failed=1
  fi
done < "$MANIFEST"

rmdir "$TMP_DIR" 2>/dev/null || true

# dnsdist's packet cache holds the NXDOMAINs these zones produced. Without this,
# a domain added to a blocklist keeps resolving, and one removed keeps being
# blocked, until each cached entry ages out — up to maxNegativeTTL. Expunging
# costs one cold cache every 8 hours and makes a policy change take effect when
# it is loaded rather than eventually.
#
# Best effort: no packet cache configured, or dnsdist not running, is not a
# blocklist failure and must not fail this run.
if ((updated > 0)) && command -v dnsdist >/dev/null 2>&1; then
  if dnsdist -c -e 'local c = getPool(""):getCache() if c then c:expungeByName(newDNSName("."), DNSQType.ANY, true) end' >/dev/null 2>&1; then
    log "dnsdist packet cache expunged so the new lists take effect now"
  fi
fi

log "done: ${updated} updated, ${skipped} unchanged$([[ $failed -eq 1 ]] && echo ", 1 or more FAILED")"

if ((failed)); then
  err "at least one zone did not update. The resolver is still serving the last good lists."
  exit 1
fi
