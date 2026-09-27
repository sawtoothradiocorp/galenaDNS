#!/usr/bin/env bash
#
# galena-dns — install the external prober on the monitor host. Run as root:
#
#   sudo bash ~/galena-probe/install.sh
#
# `make monitor-deploy` puts this directory there; `make monitor-key` adds
# aws.credentials to it. Idempotent: re-run it after either.

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)

# Pinned, and checked against the digest GitHub publishes for the release asset,
# so a compromised or swapped download fails here instead of running as root.
DNSLOOKUP_VERSION=v1.12.0
DNSLOOKUP_SHA256=bedcf2a10777cd51d1b07a470e8573c4468497ef765d894bef445e0af61d2f07

say() { printf '==> %s\n' "$*"; }

say "packages: dig (bind9-dnsutils), kdig for DoQ (knot-dnsutils), boto3"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bind9-dnsutils knot-dnsutils python3-boto3 >/dev/null

say "dnslookup ${DNSLOOKUP_VERSION} for DoH3 (not packaged by Debian)"
if [[ "$(/usr/local/bin/dnslookup --version 2>/dev/null)" != *"${DNSLOOKUP_VERSION#v}"* ]]; then
  arch=$(dpkg --print-architecture)
  [[ $arch == amd64 ]] || { echo "pinned digest is for amd64; this host is ${arch}" >&2; exit 1; }
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/d.tgz" \
    "https://github.com/ameshkov/dnslookup/releases/download/${DNSLOOKUP_VERSION}/dnslookup-linux-amd64-${DNSLOOKUP_VERSION}.tar.gz"
  echo "${DNSLOOKUP_SHA256}  $tmp/d.tgz" | sha256sum -c --quiet -
  tar -xzf "$tmp/d.tgz" -C "$tmp"
  install -m 0755 "$(find "$tmp" -type f -name dnslookup | head -1)" /usr/local/bin/dnslookup
fi

say "service user"
id galena-probe >/dev/null 2>&1 ||
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin galena-probe

say "configuration"
# 0755, not 0750: `make monitor-check` dry-runs as the admin user, who must be
# able to traverse this to read probe.env. With 0750 root:galena-probe it could
# not, and monitor-check printed nothing — found during the 2026-09-27 fire drill.
# The key is protected by its own 0640 root:galena-probe, not by the directory.
install -d -m 0755 -o root -g root /etc/galena-probe
# Not secret — domain, node addresses, topic ARN.
install -m 0644 -o root -g root "$SRC/probe.env" /etc/galena-probe/probe.env
new_key=0
if [[ -s "$SRC/aws.credentials" ]]; then
  install -m 0640 -o root -g galena-probe "$SRC/aws.credentials" /etc/galena-probe/aws.credentials
  shred -u "$SRC/aws.credentials" 2>/dev/null || rm -f "$SRC/aws.credentials"
  new_key=1
  say "  installed the AWS key and removed the copy from ${SRC}"
elif [[ ! -s /etc/galena-probe/aws.credentials ]]; then
  echo "WARNING: no AWS key yet. Run 'make monitor-key' from the repo, then re-run this." >&2
fi

say "prober and timer"
install -d -m 0755 /usr/local/lib/galena-probe
install -m 0755 "$SRC/galena-probe" /usr/local/lib/galena-probe/galena-probe
install -m 0644 "$SRC/galena-probe.service" "$SRC/galena-probe.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now galena-probe.timer >/dev/null

if ((new_key)); then
  # Proves the whole path once — this key can publish, the topic exists, the
  # email subscription is confirmed — rather than waiting for a real failure.
  say "test alert (check your inbox)"
  runuser -u galena-probe -- bash -c 'set -a; . /etc/galena-probe/probe.env
    export AWS_SHARED_CREDENTIALS_FILE=/etc/galena-probe/aws.credentials AWS_CONFIG_FILE=/dev/null
    exec /usr/local/lib/galena-probe/galena-probe --test-alert'
fi

if [[ -s /etc/galena-probe/aws.credentials ]]; then
  say "first run"
  systemctl start galena-probe.service || true
  journalctl -u galena-probe.service -n 20 --no-pager -o cat
fi
# list-timers, not NextElapseUSecRealtime: an OnUnitActiveSec timer only has a
# monotonic next-elapse, so the realtime property prints blank.
say "done. Next run:"
systemctl list-timers galena-probe.timer --no-pager | sed -n 2p
