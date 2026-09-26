# galena-dns

A public, non-logging, ad/tracker/malware-blocking encrypted DNS resolver on
Hetzner Cloud. Terraform for the infrastructure, dnsdist for the encrypted
front end, unbound for full recursion from the root.

Speaks **DoH**, **DoH3**, **DoT** and **DoQ**. Nothing listens on port 53.
Nothing about a query reaches disk, and `make audit` proves it on the running
server rather than asking you to trust the config.

See [PRIVACY.md](PRIVACY.md) for exactly what is and is not retained.

---

## How it fits together

```
        DoH  443/tcp ─┐
        DoH3 443/udp ─┤
        DoT  853/tcp ─┼──►  dnsdist  ──►  unbound  ──►  the root, then TLDs,
        DoQ  853/udp ─┘   (TLS, rate     (recursion,     then the domain itself
                           limiting)      DNSSEC, RPZ)
                                              │
                                    allowlist ▸ ads ▸ malware ▸ malicious IPs
```

unbound binds `127.0.0.1:53` and `[::1]:53` only, so "port 53 is closed" is true
by construction and not merely by firewall rule. There is no forwarding to any
third-party resolver anywhere in the configuration.

## Prerequisites

| Requirement | Notes |
|---|---|
| Hetzner Cloud project | API token with read+write |
| A domain in AWS Route 53 | Needed for ACME DNS-01. Any provider works if you swap the certbot plugin. |
| Terraform ≥ 1.9 | `brew install terraform` |
| `kdig` | `brew install knot` — DoT, DoH and DoQ tests |
| `dnslookup` | `brew install ameshkov/tap/dnslookup` — DoH3 tests |
| `shellcheck` (optional) | `brew install shellcheck` — used by `make check` |

Two environment variables, never files:

```sh
export HCLOUD_TOKEN=...           # Hetzner Cloud, read+write
export AWS_ACCESS_KEY_ID=...      # TXT-only IAM key, installed on the node
export AWS_SECRET_ACCESS_KEY=...
```

These are deliberately **not** Terraform variables. A sensitive Terraform variable
is still written to `tfstate` in plaintext, and anything placed in `user_data` can
be read back out of the Hetzner API for the life of the server. `make deploy`
installs them over SSH as `/etc/letsencrypt/aws.credentials` (0600) instead, so
they reach neither.

Two separate credentials, deliberately, because they have very different
lifetimes and blast radii:

**1. Terraform, for the A/AAAA records.** Runs interactively on your machine, so
it can use whatever you already have — an SSO profile is ideal because nothing
long-lived is created:

```sh
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

or set `aws_profile` in `terraform.tfvars`. It needs read access to the zone plus
`ChangeResourceRecordSets` for A and AAAA.

**2. A long-lived IAM key on the node, for certbot renewal.** This one cannot be
SSO: renewal runs unattended from a timer for years, and SSO tokens expire in
hours. Because it only ever writes `_acme-challenge` records, scope it to **TXT
only** — so a key stolen off the node cannot repoint your hostname:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:GetChange"],
      "Resource": "*" },
    { "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/YOUR_ZONE_ID",
      "Condition": {
        "ForAllValues:StringEquals": {
          "route53:ChangeResourceRecordSetsRecordTypes": ["TXT"]
        }
      }
    }
  ]
}
```

`make deploy` reads that key from `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
and installs it on the node. If you use a profile for Terraform and a key for the
node, export the key only for the `make deploy` step.

`make deploy` **refuses to run if `AWS_SESSION_TOKEN` is set**, because that means
temporary SSO or STS credentials. Those would issue a certificate today and then
expire, so renewal would fail silently within hours and dnsdist would serve an
expired certificate — the exact outage this repo works hardest to avoid.

If you would rather give Terraform no Route 53 access at all, set
`manage_dns_records = false` — the AWS provider then needs no credentials
whatsoever, and `make nodes` prints the records for you to create by hand.

## Deploy

```sh
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars      # domain, acme_email, admin_cidr

make check      # validate everything offline — no cost
make plan       # see what would be created — no cost
make apply      # PROMPTS, then creates billable resources
make nodes      # prints the records Terraform created
```

`make plan` reads the Route 53 hosted zone, so it needs AWS credentials in your
environment too, not just `HCLOUD_TOKEN` — an SSO profile is fine. It still
creates nothing.

Two traps here, both of which fail loudly rather than quietly:

- Terraform authenticates to AWS through `aws_profile` (an SSO profile), while the
  *node's* certbot uses the scoped IAM user's static keys. If both are present the
  provider refuses to choose — `A Profile was specified along with the environment
  variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY`. So source the ACME
  credentials for `make deploy` only, and `unset AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY` before `make plan` or `make apply`. An expired SSO token
  shows up the same way; `aws sso login --profile <name>` fixes it.
- `make apply` and `make destroy` prompt for a typed confirmation, so they need a
  real terminal. Run them from an interactive shell — piped or non-tty stdin gets
  a message telling you so, not an unattended apply.

Terraform creates the A/AAAA records itself, so there is no manual DNS step.
Both nodes' addresses go into one record set, which gives round-robin:

```
base.dns.swthrc.com.   A      <ipv4 of each node>
base.dns.swthrc.com.   AAAA   <ipv6 of each node>
```

Reverse DNS is set too, in `terraform/rdns.tf`. Both addresses get a PTR of
`base.dns.swthrc.com` rather than Hetzner's default
`static.17.3.28.2.clients.your-server.de`. The PTR lives at Hetzner because the
reverse zones for their ranges are delegated to them, so it will never appear in
the Route 53 zone. Nothing in DoH/DoT/DoQ validates a PTR — this is so the node
is identifiable as ours to abuse desks and traceroutes. With several nodes they
all share one PTR, which stays forward-confirmed because the A/AAAA record set
already lists every node.

ACME does not wait on these — certbot creates and removes its own
`_acme-challenge` TXT record — so you can deploy immediately:

```sh
make deploy     # push config, issue the certificate, start everything
make audit      # assert the privacy properties on the server
make test       # verify all four transports, DNSSEC and blocking
```

On the first run consider `acme_staging = true` in `terraform.tfvars` to avoid
burning Let's Encrypt rate limits while you get DNS-01 working, then flip it to
`false` and re-run `make deploy`. Staging certificates are not publicly trusted,
so pass `--insecure` to the test script while staging is on.

### Adding a second location later

Add a key to `nodes`. Because it is a map rather than a `count`, the existing node
is untouched:

```hcl
nodes = {
  fsn1-a = { location = "fsn1" }
  hel1-a = { location = "hel1" }   # new
}
```

Then `make apply` — which adds the new address to the existing record set
automatically — and `make deploy`. Each node gets its own certificate for the
shared name, which is exactly why ACME here is DNS-01 and not HTTP-01.

## Client setup

**Android 9+** — Settings ▸ Network & internet ▸ Private DNS ▸ Private DNS provider
hostname ▸ `base.dns.swthrc.com`. This is DoT.

**iOS / macOS** — `make mobileconfig` generates two unsigned profiles, DoH and
DoT. AirDrop or email one to the device and install it:

- iOS: Settings ▸ General ▸ VPN, DNS & Device Management
- macOS: System Settings ▸ General ▸ Device Management

Settings will label them "Unverified" because they are not signed with an Apple
developer certificate. That concerns the profile file, not the DNS connection —
the OS still validates your certificate on every query. Only one DNS profile can
be active at a time, so installing one replaces the other.

**Firefox** — Settings ▸ Privacy & Security ▸ DNS over HTTPS ▸ Max Protection ▸
Custom ▸ `https://base.dns.swthrc.com/dns-query`

**Chrome / Edge** — Settings ▸ Privacy and security ▸ Security ▸ Use secure DNS ▸
With: Custom ▸ `https://base.dns.swthrc.com/dns-query`

**Windows 11** — Settings ▸ Network & internet ▸ your adapter ▸ DNS server
assignment ▸ Edit ▸ add the node's IP, then set DNS over HTTPS to your URL.

**Routers / systemd-resolved** — point at the node IP with DoT and set the TLS
hostname to `base.dns.swthrc.com`.

## Blocking

Four policy zones, applied in this order, first match wins:

| Zone | Source | Entries | Blocks |
|---|---|---|---|
| `allowlist` | `node/unbound/rpz/allowlist.rpz` | yours (empty by default) | overrides everything below |
| `adblock` | Hagezi Pro | ~456,000 | ads, trackers, telemetry |
| `threat` | Hagezi TIF medium | ~1,747,000 | malware, phishing, scams, C2 |
| `threatip` | Hagezi TIF IPs | ~60,000 | resolution *to* malicious IPs |

Order is not cosmetic. In RPZ a `PASSTHRU` is itself a match, and a match stops
unbound evaluating any later zone — so the allowlist only works because it is
first. `bootstrap.sh` emits it ahead of the list unconditionally, and `make audit`
checks that it really is first.

Hagezi publishes no RPZ allowlist, so that zone is yours to maintain here in the
repo. Edit it and re-run `make deploy`.

### Allowlisting something

To allow a domain — note owner names are **relative**, which is how RPZ encodes
triggers, so a bare `example.com` is correct and a trailing dot is wrong:

```
example.com            CNAME rpz-passthru.
*.example.com          CNAME rpz-passthru.
```

To allow an **IP address**, which is what you need when `threatip` misfires on a
shared CDN address. The format is `prefixlength.reversed-octets.rpz-ip`, so
`203.0.113.42/32` becomes:

```
32.42.113.0.203.rpz-ip CNAME rpz-passthru.
```

### Live triage

```sh
unbound-control rpz_disable threat.rpz.galena     # drop one layer, no restart
unbound-control rpz_enable  threat.rpz.galena
unbound-control auth_zone_reload allowlist.rpz.galena
```

If the threat feed is too aggressive for you, swap `rpz/tif.medium.txt` for
`rpz/tif.mini.txt` (~401,000 entries) in `rpz_blocklists`, or set
`enable_threat_ip_blocking = false` to drop just the response-IP layer.

### Updates

A systemd timer refreshes every 8 hours, matching Hagezi's publish cadence, with
a randomised delay. Each feed is fetched, **validated**, swapped in atomically,
and reloaded; if unbound rejects the new zone it is rolled back to the previous
copy. Zones are processed one at a time so two 46 MB reloads never overlap.

Validation is not paranoia. Hagezi's full `rpz/tif.txt` is over jsdelivr's 150 MB
limit, and jsdelivr reports that as a **143-byte HTTP 200** — a naive fetcher
installs those 143 bytes as your blocklist and reports success. The validator
rejects short bodies, HTML, missing `$TTL` or `SOA`, and any feed that comes back
with fewer than `min_entries` records.

## What the privacy audit checks

`make audit` runs 11 sections on the server and exits nonzero on any FAIL:

1. **Sockets** — nothing on port 53 except loopback; all four transports bound.
2. **Logging** — journald `Storage=volatile`; no `/var/log/journal`; rsyslog,
   syslog-ng, auditd and sysstat not installed; no `log` statement in nftables.
3. **unbound runtime and recursion** — queries the *running* daemon via
   `unbound-control get_option` for all 14 privacy settings, so a config edited
   but never reloaded cannot pass. Confirms ECS is not loaded and not echoed to
   clients. Then three recursion-integrity checks: no forward zone,
   `unbound-resolvconf` masked, and a behavioural test that asks an authoritative
   server which address it sees and fails if it is not one of this node's.
4. **Policy zones** — every zone has `rpz-log: no`, and the allowlist is first.
   Reports per-zone record counts and file sizes.
5. **dnsdist** — config is free of every logging and remote-logging directive;
   `setSecurityPollSuffix("")` present so there is no version phone-home;
   responses not recorded; webserver state matches the variable.
6. **Outbound connections** — flags anything established to a port that is not
   DNS, ACME or the blocklist CDN, which is what a remote log sink would look like.
7. **Scheduled jobs** — unexpected cron entries and the active timer list.
8. **Host resolver** — `/etc/resolv.conf` points only at `127.0.0.1`, so the
   server's own lookups do not reach a third-party resolver, and is immutable.
9. **Known on-disk data** — reports what *is* written (certbot and apt logs) rather
   than staying quiet about it.
10. **Empirical probe** — sends a query with a randomly generated name, then greps
    the writable filesystem and the journal for it. This is the check that catches
    what a config review misses.

Plus a memory report, since the blocklists are what will run you out of RAM first.

## Testing

```sh
make test
make test ARGS=--include-ratelimit    # will dynblock your own address
```

It checks all four transports, DNSSEC (a bogus signature must SERVFAIL and a good
one must set the AD bit), a known ad domain, malware domains **sampled live from
the deployed feeds**, the allowlist, and that port 53 is closed.

Malware fixtures are sampled rather than pinned because individual malware domains
get delisted within weeks, so a hardcoded one becomes a scheduled false failure.
The ad fixture stays pinned as a stable canary.

Two honest caveats the output states for itself:

- **Port 53 closed is a weak pass.** Many networks block outbound 53, so a timeout
  may be your network rather than the server. Re-run from a second network.
- **Neither `kdig` nor `dig` can speak DoH3.** kdig's `+https` is libnghttp2,
  which is HTTP/2 only; `dig` has no QUIC transport at all. Hence `dnslookup`.
  If it is missing, the DoH3 test SKIPs loudly instead of passing quietly.

The allowlist ships **empty**, so nothing is un-blocked by default. The allowlist
check reads `node/unbound/rpz/allowlist.rpz` and tests whatever plain-domain
entries you have added, reporting SKIP while there are none. Wildcard and
`rpz-ip` entries are skipped on purpose: querying an invented label under a
wildcard usually returns a genuine upstream NXDOMAIN, which looks identical to the
allowlist failing and would be a false alarm.

With the allowlist empty, zone order is still verified — `make audit` section 4
checks structurally that the allowlist zone is evaluated first, which is the
property that matters.

## Design choices

**dnsdist 2.1 from repo.powerdns.com, not Debian.** Incoming DoQ and DoH3 landed
in dnsdist 1.9.0 and need Cloudflare's quiche; Debian's package is far older. The
official packages statically link quiche, and `bootstrap.sh` refuses to continue
if `dnsdist --version` does not report both `dns-over-quic` and `dns-over-http3`.

**Lua config, not dnsdist 2.x YAML.** Every upstream example for DoQ, DoH3 and
dynamic blocks is Lua, the privacy-relevant functions are documented as Lua, and
upstream advises against mixing the two forms.

**Debian 13.** unbound 1.26.1 (via trixie updates) against Debian 12's 1.17.1, plus certbot 4.0.0 with
an apt-installable Route 53 plugin (`python3-certbot-dns-route53` 4.0.0-1).

**ACME DNS-01, not HTTP-01.** With two or more nodes behind round-robin A records
for one hostname, Let's Encrypt connects to *one* address and validation fails on
the others. DNS-01 is node-count independent and needs no inbound port 80 at all,
so no HTTP server ever runs and there are no access logs. The cost is a scoped
IAM key on each node.

`certbot-dns-route53` has no `--credentials` flag and takes its key from the
environment, so renewal — which runs from `certbot.timer` with a clean
environment — needs `node/systemd/certbot.service.d/aws-credentials.conf`.
Without that drop-in renewal fails silently about 60 days in.

**The deploy hook is load-bearing.** dnsdist does not watch certificate files on
disk. Without `reloadAllCertificates()` after renewal it keeps serving the old
certificate until the process restarts — meaning it would happily serve an expired
certificate a month after a successful renewal.

**DNS records are in Terraform, credentials are not.** The A/AAAA records are not
secret and belong in state where they can be kept in step with the node addresses.
The IAM key is a different matter: a sensitive Terraform variable is written to
`tfstate` in plaintext, so the key only ever reaches the node over SSH.

**Terraform provisions, `make deploy` configures.** Hetzner caps `user_data` at
32 KiB and the full config tree does not fit with any headroom. The split also
means config changes are a re-deploy rather than a server rebuild, and
`user_data` never has to carry a secret.

**`cx23` by default, not `cpx22`.** After Hetzner's June 2026 price adjustment
CPX22 is €19.49/mo against CX23's €5.49 for the same 4 GB, and this workload does
not need the extra CPU.

**Rate limiting is two layers.** `MaxQPSIPRule` is an inline per-IP ceiling that
needs no state. Dynamic blocks catch sustained abuse but are computed from
dnsdist's in-RAM ring, which is the only place client IPs and query names exist
at all — see PRIVACY.md. Set `dynblock_ring_entries = 0` to eliminate that window
entirely at the cost of dynamic blocking.

**ICMP is allowed on purpose.** QUIC depends on path MTU discovery. Dropping
"fragmentation needed" and ICMPv6 "packet too big" produces the worst class of
bug: DoQ and DoH3 work from most networks and hang from a few.

**journald is volatile, and that has a cost.** If dnsdist or unbound crash-loops
across a reboot there is no forensic trail. Use `journalctl -f` while reproducing.

## Memory

This is the binding constraint. ~2.26M RPZ entries across three zones is roughly
0.9–1.2 GB resident, which is why the unbound caches are sized explicitly
(`msg-cache-size: 128m`, `rrset-cache-size: 256m`) rather than left at defaults,
and why `unbound.service` gets a `MemoryMax` so a runaway zone restarts unbound
instead of letting the OOM killer pick sshd.

`make audit` reports per-zone counts and process RSS so growth is visible before
it hurts. On a 2 GB server type, `rpz/tif.mini.txt` is the required swap.

## Layout

```
terraform/          infrastructure: server, firewall, SSH key, cloud-init
  dns.tf            Route 53 A/AAAA records for the resolver hostname
  rdns.tf           PTR records at Hetzner for each node's addresses
  templates/        cloud-init (minimal: base packages, SSH, volatile logging)
node/               rsynced to /opt/galena, installed by bootstrap.sh
  bootstrap.sh      idempotent configure; ordering matters, see its header
  unbound/          unbound.conf + the allowlist RPZ zone
  dnsdist/          dnsdist Lua config
  nftables/         host firewall
  systemd/          journald privacy, RPZ timer, service hardening, certbot AWS env
  bin/              rpz-update.sh, acme-deploy-hook.sh, privacy-audit.sh
scripts/            run from your machine: test-resolver.sh, make-mobileconfig.sh
```

## Pinned versions

| Component | Version | Why |
|---|---|---|
| hcloud provider | `~> 1.69` | current minor series; patches yes, breaking changes no |
| aws provider | `~> 6.66` | Route 53 records only |
| Terraform | `>= 1.9` | `optional()` with defaults in object types |
| Debian | 13 (trixie) | unbound 1.26.1, certbot 4.0.0 |
| dnsdist | 2.1.x | current stable; DoQ/DoH3 require ≥ 1.9.0 |
| unbound | 1.26.1 (distro) | security-tracked by Debian; trixie has moved past the 1.22.0 it released with |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `certbot` fails during deploy | IAM key lacks `route53:ChangeResourceRecordSets` on the zone, or the name is not in a Route 53 hosted zone |
| `terraform plan` fails on the zone lookup | AWS credentials missing from your environment, or the key lacks `route53:ListHostedZonesByName` |
| `apply` fails with a record conflict | The A/AAAA record already exists outside state. Delete it, or import it, or set `manage_dns_records = false` |
| Renewal fails ~60 days later | The certbot systemd drop-in is missing; check `systemctl cat certbot.service` |
| Renewal fails within hours | Temporary SSO/STS credentials were installed. `make deploy` blocks this, but check `/etc/letsencrypt/aws.credentials` for a session token |
| `bootstrap.sh` aborts on QUIC support | apt resolved dnsdist from Debian — check `apt-cache policy dnsdist` |
| DoT/DoH work, DoQ/DoH3 hang for some users | ICMP being dropped upstream of the node, breaking path MTU discovery |
| Everything resolves but nothing is blocked | Check `make audit` section 4; a feed may have failed validation |
| A DNS leak test shows your provider's resolvers | unbound is forwarding rather than recursing. `unbound-control list_forwards` should be empty and `unbound-resolvconf.service` masked; `make audit` section 3 checks both |
| Allowlist entries ignored | The allowlist zone is not first — `make audit` checks this |
| TLS handshake fails after ~60 days | The deploy hook is not running; `certbot renew --dry-run` |
| unbound OOMs or restarts | Swap `tif.medium.txt` for `tif.mini.txt`, or use a larger server type |

```sh
make ssh                                  # get onto the node
journalctl -u dnsdist -u unbound -f       # RAM only, nothing persisted
systemctl start rpz-update.service        # refresh blocklists now
unbound-control list_auth_zones           # what is actually loaded
```

## Costs

One `cx23` in an EU location is about **€5.49/month** plus VAT. `make apply`
prints an estimate and requires you to type `yes`; `make destroy` asks twice.
Traffic is included up to the plan's allowance.

## License

Configuration in this repository is yours to use. Blocklists are Hagezi's, under
[their license](https://github.com/hagezi/dns-blocklists/blob/main/LICENSE).
