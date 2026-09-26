#!/usr/bin/env bash
#
# galena-dns — generate unsigned iOS/macOS configuration profiles.
#
# Two files, not one: iOS and macOS honour a single com.apple.dnsSettings.managed
# payload per profile, so a profile carrying both DoH and DoT is ambiguous about
# which one applies. Install whichever you want; DoH is the better default.
#
# The profiles are UNSIGNED, so Settings will show them as "Unverified". That is
# expected and says nothing about the DNS connection itself, which is
# certificate-validated by the OS against your Let's Encrypt cert.
#
# PayloadUUIDs are derived from the domain with UUID5, so regenerating produces
# identical UUIDs and a reinstall REPLACES the existing profile rather than
# stacking a second copy.

set -euo pipefail

DOMAIN=""
OUT_DIR="."
DOH_PATH="/dns-query"
declare -a ADDRS=()

usage() {
  cat <<EOF
Usage: $0 --domain <fqdn> [--out <dir>] [--address <ip>]...

  --domain FQDN    Your resolver's hostname (must match its certificate)
  --out DIR        Where to write the .mobileconfig files (default: .)
  --address IP     Optional bootstrap address, repeatable. Lets the device reach
                   the resolver without first resolving its name in plaintext.
  -h, --help       This.
EOF
}

while (($#)); do
  case $1 in
    --domain) DOMAIN=$2; shift 2 ;;
    --out) OUT_DIR=$2; shift 2 ;;
    --address) ADDRS+=("$2"); shift 2 ;;
    --doh-path) DOH_PATH=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n $DOMAIN ]] || {
  echo "--domain is required" >&2
  exit 2
}
command -v python3 >/dev/null || {
  echo "python3 is required (for stable UUID5 generation)" >&2
  exit 1
}
mkdir -p "$OUT_DIR"

# Stable UUIDs: same domain and slot always yield the same UUID.
uuid_for() {
  python3 -c "import uuid,sys; print(str(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1])).upper())" \
    "galena-dns://${DOMAIN}/$1"
}

# <string> entries for any bootstrap addresses.
addr_xml=""
if ((${#ADDRS[@]})); then
  addr_xml=$'\n\t\t\t<key>ServerAddresses</key>\n\t\t\t<array>'
  for a in "${ADDRS[@]}"; do
    addr_xml+=$'\n\t\t\t\t<string>'"${a}"$'</string>'
  done
  addr_xml+=$'\n\t\t\t</array>'
fi

emit() {
  local slot=$1 proto=$2 settings=$3 label=$4
  local outer inner file
  outer=$(uuid_for "${slot}/outer")
  inner=$(uuid_for "${slot}/inner")
  file="${OUT_DIR}/galena-dns-${DOMAIN}-${slot}.mobileconfig"

  cat > "$file" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
	<key>PayloadIdentifier</key>
	<string>dns.galena.${DOMAIN}.${slot}</string>
	<key>PayloadUUID</key>
	<string>${outer}</string>
	<key>PayloadDisplayName</key>
	<string>${label} — ${DOMAIN}</string>
	<key>PayloadDescription</key>
	<string>Routes all DNS queries on this device to ${DOMAIN} over ${label}. Ads, trackers and known malware domains are filtered. No queries are logged.</string>
	<key>PayloadOrganization</key>
	<string>galena-dns</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadType</key>
			<string>com.apple.dnsSettings.managed</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
			<key>PayloadIdentifier</key>
			<string>dns.galena.${DOMAIN}.${slot}.settings</string>
			<key>PayloadUUID</key>
			<string>${inner}</string>
			<key>PayloadDisplayName</key>
			<string>${label} Settings</string>
			<key>DNSSettings</key>
			<dict>
				<key>DNSProtocol</key>
				<string>${proto}</string>
${settings}${addr_xml}
			</dict>
		</dict>
	</array>
</dict>
</plist>
XML

  # plutil is macOS-only; on Linux fall back to python's plist parser so the
  # output is still validated rather than assumed good.
  if command -v plutil >/dev/null; then
    plutil -lint "$file" >/dev/null || {
      echo "generated an invalid plist: ${file}" >&2
      exit 1
    }
  else
    python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' "$file" || {
      echo "generated an invalid plist: ${file}" >&2
      exit 1
    }
  fi
  printf '  %s\n' "$file"
}

printf 'Generated unsigned profiles for %s:\n' "$DOMAIN"
emit doh HTTPS $'\t\t\t\t<key>ServerURL</key>\n\t\t\t\t<string>https://'"${DOMAIN}${DOH_PATH}"$'</string>' "DNS over HTTPS"
emit dot TLS $'\t\t\t\t<key>ServerName</key>\n\t\t\t\t<string>'"${DOMAIN}"$'</string>' "DNS over TLS"

cat <<EOF

Install: AirDrop or email the file to the device, open it, then
  iOS     Settings > General > VPN, DNS & Device Management > the profile > Install
  macOS   System Settings > General > Device Management > the profile > Install

Settings will say "Unverified" because the profile is not signed with an Apple
developer certificate. That is about the profile file, not the DNS connection —
the OS still validates ${DOMAIN}'s certificate on every query.

Only one DNS profile can be active at a time; installing the other replaces it.
These files are gitignored: they embed your hostname.
EOF
