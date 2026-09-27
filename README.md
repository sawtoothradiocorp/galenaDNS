# galena-dns

A public, non-logging, ad/tracker/malware-blocking encrypted DNS resolver on
Hetzner Cloud. Terraform for the infrastructure, dnsdist for the encrypted front
end, unbound for DNSSEC validation and policy, forwarding upstream over
authenticated DNS-over-TLS.

Speaks **DoH**, **DoH3**, **DoT** and **DoQ**. Nothing listens on port 53.
Nothing about a query reaches disk *here*, and `make audit` proves it on the
running server rather than asking you to trust the config. Queries do reach an
upstream resolver, which is a deliberate trade — see "Design choices" and
PRIVACY.md, where it is the first thing disclosed.

See [PRIVACY.md](PRIVACY.md) for exactly what is and is not retained.

---

## How it fits together

```
        DoH  443/tcp ─┐
        DoH3 443/udp ─┤
        DoT  853/tcp ─┼──►  dnsdist  ──►  unbound  ──►  Quad9 over DoT 853
        DoQ  853/udp ─┘   (TLS, rate     (DNSSEC, RPZ,    (dns.quad9.net,
                           limiting)      forwarding)      malware filtering)
                                              │
                                    allowlist ▸ ads ▸ malicious IPs
```

unbound binds `127.0.0.1:53` and `[::1]:53` only, so "port 53 is closed" is true
by construction and not merely by firewall rule.

**Resolution posture.** unbound forwards the root zone to Quad9 over authenticated
DNS-over-TLS rather than recursing from the root. That is a deliberate privacy
trade and the reasoning is in `terraform/variables.tf` above
`forward_tls_upstreams`, in PRIVACY.md, and summarised under "Design choices"
below. In one line: recursion is cleartext, so it hands the hosting provider every
query name on top of the client IPs it already sees, while forwarding over TLS
splits those two halves between two parties who would have to collude.

Set `forward_tls_upstreams = []` for full recursion with no third party. DNSSEC is
validated locally either way, so the upstream is only ever trusted to relay.

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

Terraform creates the A/AAAA records itself, so there is no manual DNS step. Each
node gets its own record set under the shared name, distinguished by a set
identifier, with a multivalue-answer routing policy:

```
base.dns.swthrc.com.   A      <ipv4 of node>   set=fsn1-a   TTL 60   hc
base.dns.swthrc.com.   A      <ipv4 of node>   set=hel1-a   TTL 60   hc
base.dns.swthrc.com.   AAAA   <ipv6 of node>   set=fsn1-a   TTL 60   hc
base.dns.swthrc.com.   AAAA   <ipv6 of node>   set=hel1-a   TTL 60   hc
```

Route 53 returns up to 8 of the **healthy** values in random order, so clients still
spread across nodes — and a dead node stops being handed out. `hc` is the attached
health check; see "Failover" below for why the shape is one record set per node
rather than one record set with two values.

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
make apply      # ALSO required after any tfvars change — see below
make deploy     # push config, issue the certificate, start everything
make audit      # assert the privacy properties on the server
make test       # verify all four transports, DNSSEC and blocking
```

**Any change to `terraform.tfvars` or `variables.tf` needs `make apply` before
`make deploy`, even when it changes no infrastructure.** The node's settings are
pushed from `terraform output`, and outputs are stored in state rather than
recomputed on demand — so without the apply, `make deploy` would push the previous
values. It refuses instead of doing that quietly.

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

Then `make apply` — which adds the new record set and, above one node, its health
checks — and `make deploy`. Each node gets its own certificate for the shared name,
which is exactly why ACME here is DNS-01 and not HTTP-01.

### Failover

**A second node on its own gives distribution, not failover.** A DoT or DoH client
resolves the hostname once, picks one address and holds that connection for its
life, so it is pinned to a single node rather than alternating per query. When that
node dies, its clients get errors until they retry, and Android surfaces "Private
DNS server cannot be accessed" before it recovers.

Route 53 health checks are what close that gap. Each record set carries one, and an
address whose check is failing is not returned:

| | |
|---|---|
| Probe | TCP connect to 853 (DoT), from Route 53's ~15 checker regions |
| Unhealthy when | more than 18% of regions disagree, for 3 consecutive rounds |
| Detection | `dns_health_check_interval` × `dns_health_check_failure_threshold` = 90s |
| Client recovery | detection + `dns_record_ttl`, so ~150s at TTL 60 |
| Cost | $0.75/check/month — one per node per address family, so $3.00 for two nodes |

`make nodes` prints the live numbers rather than these, so the two cannot drift.

Terraform state holds the configuration, not Route 53's verdict, so to ask what it
actually thinks right now:

```sh
cd terraform && terraform output dns_health_checks     # ids, per node and family
aws route53 get-health-check-status --health-check-id <id>
```

This is also why `dns_record_ttl` is 60 here and not the 300 default: the TTL is the
half of the recovery time Route 53 cannot shorten for you, because resolvers that
already cached the dead address keep serving it until it expires.

One side effect worth knowing: **a node is withdrawn from DNS until it is deployed.**
A freshly created node has no dnsdist, so its checks fail and Route 53 does not hand
its address out. Before health checks, `make apply` put a dead address into rotation
immediately and clients hit it until `make deploy` finished. Now the node joins when
it starts answering, which makes adding a location a non-event for clients.

**What a TCP check proves, and what it does not.** It proves the node is reachable
and something is accepting DoT connections — which covers the failures that actually
take a node out: the VM gone, the network gone, dnsdist dead. It does *not* prove the
certificate is valid (Route 53 completes a TCP handshake, not a TLS one), that unbound
is alive behind dnsdist (a dead backend still gets a green check and answers SERVFAIL),
or that DoH, DoH3 and DoQ work (separate listeners, unprobed). Route 53 has no
DNS-aware check type, so closing those gaps needs an external prober that speaks DNS —
[BACKLOG.md](BACKLOG.md) section 1. Health checks remove a dead address automatically;
that item is what watches for the quiet failures.

Nothing in the firewall had to change: both layers already accept tcp/853 from
anywhere, and neither rate-limits new connections on it.

Turn it off with `enable_dns_failover = false`, or halve the cost with
`dns_health_check_ipv6 = false` — which accepts that IPv4 can be healthy while
IPv6 is broken, leaving v6-only clients pinned to a node that cannot answer them.
It is ignored entirely with a single node: Route 53 returns every value when all of
them are unhealthy, so one checked node behaves exactly like an unchecked one.

**Migrating an existing single record set.** A record set with a set identifier
cannot coexist with one without, so switching an already-deployed simple record set
to this shape means Terraform deletes the old one and creates the new ones. The
delete has no dependencies and the creates wait on the nodes and their health
checks, so Terraform orders it correctly on its own; if it ever does not, Route 53
rejects the create, the old record survives and the apply is safe to re-run. During
the switch the name has no A/AAAA for under a minute — resolvers holding a cached
answer are unaffected, fresh lookups fail.

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

Blocking happens in two places, and the difference matters because only one of
them is yours to override.

**Locally, as RPZ** — four policy zones, applied in this order, first match wins:

| Zone | Source | Entries | Blocks |
|---|---|---|---|
| `allowlist` | `node/unbound/rpz/allowlist.rpz` | yours (empty by default) | overrides everything below |
| `adblock` | Hagezi Pro | ~456,000 | ads, trackers, telemetry |
| `threat` | Hagezi TIF **mini** | ~401,000 | malware, phishing, scams, C2 |
| `threatip` | Hagezi TIF IPs | ~72,000 | resolution *to* malicious IPs |

**Upstream, at Quad9** — malware, phishing and C2 domains, from commercial threat
intelligence updated continuously.

Malware is blocked in both places on purpose, because the measurement below showed
the two catch different things. The local feed is the **mini** list rather than the
medium one that used to be here: medium's 1,747,000 entries cost roughly 0.9-1.2 GB
and were what forced the caches down to 128m/256m. Mini is about a fifth of that.

`threatip` is local because nothing else can do it. It triggers on the *answer*,
blocking resolution to known command-and-control addresses whatever domain was
asked for, which catches brand-new and compromised domains no domain-reputation
feed knows about yet. Quad9 filters by domain and does not replace it.

The cost of upstream filtering is that **you cannot allowlist around an upstream
block** — see "Overriding an upstream block" below.

### Two things measured after the switch

**An upstream block on a DNSSEC-signed zone surfaces as SERVFAIL, not NXDOMAIN.**
Quad9 denies a blocked name with an unsigned NXDOMAIN. For a signed parent zone our
local validator correctly refuses to accept a forged denial, so the client sees
SERVFAIL. Measured: `bahasay.africa` gives SERVFAIL normally and NXDOMAIN with
`+cdflag`, while `2feet4paws.ae` (unsigned parent) gives NXDOMAIN either way.

The name is still blocked, and the validator behaving this way is correct. But it
is worth knowing, because **some clients retry SERVFAIL against a fallback
resolver**, which both defeats the block and sends that query somewhere else. A
locally blocked name never has this problem, since RPZ rewrites are not validated
against the real zone. If that matters to you, keep malware blocking local.

**Quad9 and Hagezi TIF medium overlap less than you might assume.** Of 57 sampled
domains from that feed, Quad9's filtered endpoint blocked 9; the other 48 resolved
normally through both Quad9 and Google. This test cannot tell you which list is
right — Quad9 may be more precise, or Hagezi may have broader coverage, and the
sample contained subdomains of real businesses that look like plausible
over-blocking. It does mean the two are **not equivalent**, and that moving malware
blocking upstream changed what is blocked rather than simply relocating it.

This is why `tif.mini.txt` runs locally *alongside* the upstream rather than
instead of it: a fifth of the medium feed's memory, and the two disagree often
enough that running both is worth it. A local block is also the better-behaved of
the two, since it returns a clean NXDOMAIN rather than the SERVFAIL described
above. `make test` re-measures the overlap every run as a side effect of
discovering its canary.

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

### Overriding an upstream block

The allowlist cannot undo a block made by Quad9. An upstream NXDOMAIN arrives as
an answer, so it never reaches response-policy processing and `rpz-passthru` has
nothing to act on. Confirm that is what you are looking at before reaching for
this — a local block and an upstream block both look like NXDOMAIN:

```sh
# On the node. If this answers but the resolver does not, the block is upstream.
dig +short @9.9.9.10 example.com          # Quad9 unfiltered
dig +short @127.0.0.1 example.com         # what we serve
```

The remedy is to forward that one name to Quad9's unfiltered endpoint, in
`node/unbound/unbound.conf.tmpl`, then `make deploy`:

```
forward-zone:
    name: "example.com"
    forward-tls-upstream: yes
    forward-first: no
    forward-addr: 9.9.9.10@853#dns10.quad9.net
    forward-addr: 2620:fe::10@853#dns10.quad9.net
```

A more specific `forward-zone` wins over `.`, so only that name bypasses
filtering. Everything else stays filtered. Note that this is a manual operator
action with a deploy behind it, not something the allowlist does for you — that is
the real cost of moving malware blocking upstream. If you would rather never be in
this position, set `forward_tls_upstreams` to Quad9's unfiltered endpoint
(`dns10.quad9.net`) and add a malware feed back to `rpz_blocklists`, which puts the
entire blocking policy back in your hands.

You can also report a false positive to Quad9, who run a remediation process, but
that is their timeline and not yours.

### Live triage

```sh
unbound-control rpz_disable adblock.rpz.galena    # drop one layer, no restart
unbound-control rpz_enable  adblock.rpz.galena
unbound-control auth_zone_reload allowlist.rpz.galena
```

Set `enable_threat_ip_blocking = false` to drop the response-IP layer, which is the
most false-positive-prone of the local zones — one shared CDN address in the feed
takes out every site behind it.

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
3. **unbound runtime and resolution posture** — queries the *running* daemon via
   `unbound-control get_option` for all 14 privacy settings, so a config edited
   but never reloaded cannot pass. Confirms ECS is not loaded and not echoed to
   clients. Then asserts the posture that is actually configured, in either
   direction:
   - forwarding: the running forward zone matches `forward_tls_upstreams`, the
     transport is TLS, every upstream carries a `#tls-auth-name` so the
     certificate is verified rather than opportunistic, `forward-first: no` so an
     unreachable upstream cannot cause a silent cleartext fallback, and —
     behaviourally — an authoritative server does *not* report this node's address
   - full recursion (`forward_tls_upstreams = []`): no forward zone exists, and an
     authoritative server *does* report this node's address

   `unbound-resolvconf` must be masked in both, because it would replace a
   deliberate TLS upstream with the provider's cleartext resolvers just as readily
   as it would break recursion. These checks exist because the audit once passed
   46/46 while the resolver was silently forwarding in cleartext to the provider.
4. **Policy zones** — every zone has `rpz-log: no`, and the allowlist is first.
   Reports per-zone record counts and file sizes.
5. **dnsdist** — config is free of every logging and remote-logging directive;
   `setSecurityPollSuffix("")` present so there is no version phone-home;
   responses not recorded; webserver state matches the variable.
6. **Outbound connections** — flags anything established *from* this host to a port
   that is not DNS, ACME or the blocklist CDN, which is what a remote log sink would
   look like. Inbound and outbound are told apart by the local port, so clients on
   443/853 and the DNS health checkers probing 853 are not mistaken for egress.
7. **Scheduled jobs** — unexpected cron entries and the active timer list.
8. **Host resolver** — `/etc/resolv.conf` points only at `127.0.0.1`, so the
   server's own lookups do not reach a third-party resolver, and is immutable.
9. **Known on-disk data** — reports what *is* written (certbot and apt logs) rather
   than staying quiet about it, and names the upstream that receives query names,
   since "nothing reaches disk here" is only half the picture.
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

**Forward over DoT instead of recursing.** The one decision worth reading twice,
because the project originally did the opposite and PRIVACY.md now leads with it.

Full recursion needs no third party, which sounds strictly better — but it speaks
cleartext DNS on port 53. Resolving from the root means the hosting provider sees
every query name, and they already see every client IP arriving on 443 and 853.
One company holding both halves of the identifying pair is the worst available
outcome, and `qname-minimisation` does not help: it limits what each nameserver in
the chain learns, while a network observer watches the whole chain and reassembles
the name from the parts.

Forwarding to Quad9 over authenticated DoT splits those halves. The provider keeps
client IPs and sees only ciphertext leaving; Quad9 gets query names attributed to
this node's single address and never sees a client. Neither can reconstruct who
asked what alone. Three things fall out of it: this node becomes a mixer, so users
are more private against Quad9 than they would be querying Quad9 directly; a warm
anycast cache usually answers faster than a cold recursion chain; and the 1.75M
entry malware feed could move off the box, which is what freed the RAM for cache.

What it costs is independence. Quad9's blocking policy applies and the allowlist
cannot override it. DNSSEC is still validated *here*, so the upstream is trusted to
relay and never to tell the truth — and `forward_tls_upstreams = []` reverts the
whole decision in one line.

**A packet cache in front of unbound.** Repeated questions are answered from
dnsdist's RAM instead of crossing into unbound. On an ad-blocking resolver the most
repeated queries are the blocked ones — the same telemetry endpoints, constantly —
and each otherwise walks four RPZ zones to produce an identical NXDOMAIN.

It costs nothing privacy-wise: entries are keyed by the question, never by the
client, so like unbound's own cache it can say what was asked recently but never by
whom, and it never reaches disk. PRIVACY.md lists it with the other in-memory
structures rather than letting the document drift.

`rpz-update.sh` expunges it after any successful blocklist reload, so a newly
blocked domain is blocked when the list loads rather than whenever its cached entry
happens to expire. `temporaryFailureTTL` is a deliberate 5 seconds: an upstream
block on a signed zone arrives as SERVFAIL, and with `forward-first: no` an
unreachable upstream makes everything SERVFAIL — caching either for a minute would
turn a blip into a visible outage.

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

This used to be the binding constraint, and the numbers here are measured on the
running node rather than estimated.

**Steady state: 557 MB** for unbound with all four zones loaded (~895,000 RPZ
entries across allowlist, adblock, threat and threatip), caches cold. That works
out at ~0.62 KB per entry, and it scales linearly — 491,000 entries measured
320 MB earlier. dnsdist adds about 64 MB plus its packet cache.

**After a blocklist reload the same process reads 1366 MB**, and that is the number
to be careful with. `auth_zone_reload` holds the old and new zone simultaneously,
and glibc keeps the freed arena instead of returning it to the OS, so RSS reflects
the reload peak rather than what unbound needs. A restart drops it straight back to
557 MB.

Two things follow. `unbound_memory_max` has to cover the *peak*, not the steady
state, because systemd's `MemoryMax` acts on RSS — 2500M against a ~1.4 GB peak is
the right kind of margin and should not be "optimised" down to fit 557 MB. And a
large figure in `make audit` section 11 right after `make deploy` is usually
nothing; the audit now says so rather than leaving you to work it out.

The original 1,747,000-entry medium threat feed is what forced the caches down to
`128m`/`256m`. With it upstream and `tif.mini` in its place the caches are
`256m`/`512m`. There is room for `512m`/`1024m` — steady 557 MB plus 1.5 GB of
cache still clears the cap — but free RAM is not wasted RAM and the dnsdist packet
cache now absorbs the repeats that unbound's message cache used to.

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
| upstream resolver | `dns.quad9.net` | pinned by TLS auth name, not IP, so Quad9 can rotate addresses without breaking verification |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `certbot` fails during deploy | IAM key lacks `route53:ChangeResourceRecordSets` on the zone, or the name is not in a Route 53 hosted zone |
| `terraform plan` fails on the zone lookup | AWS credentials missing from your environment, or the key lacks `route53:ListHostedZonesByName` |
| `make deploy` refuses, saying state is behind the configuration | Outputs live in state, so a tfvars change reaches a node only after `make apply` recomputes them. Run `make apply` (it may report no infrastructure changes), then deploy |
| `make deploy` refuses, saying plan failed | Usually expired AWS SSO. It refuses rather than pushing settings it cannot confirm are current |
| `apply` fails with a record conflict | The A/AAAA record already exists outside state. Delete it, or import it, or set `manage_dns_records = false` |
| Renewal fails ~60 days later | The certbot systemd drop-in is missing; check `systemctl cat certbot.service` |
| Renewal fails within hours | Temporary SSO/STS credentials were installed. `make deploy` blocks this, but check `/etc/letsencrypt/aws.credentials` for a session token |
| `bootstrap.sh` aborts on QUIC support | apt resolved dnsdist from Debian — check `apt-cache policy dnsdist` |
| DoT/DoH work, DoQ/DoH3 hang for some users | ICMP being dropped upstream of the node, breaking path MTU discovery |
| Everything resolves but nothing is blocked | Check `make audit` section 4; a feed may have failed validation |
| A DNS leak test shows your provider's resolvers | `unbound-resolvconf` has replaced the configured upstream with the provider's cleartext resolvers. `unbound-control list_forwards` should show only `forward_tls_upstreams`; `make audit` section 3 checks that and that the service is masked |
| Allowlist entries ignored | The allowlist zone is not first — `make audit` checks this |
| TLS handshake fails after ~60 days | The deploy hook is not running; `certbot renew --dry-run` |
| unbound OOMs or restarts | Lower `unbound_msg_cache_size`/`unbound_rrset_cache_size`, or use a larger server type. `make audit` section 11 reports RSS |
| Everything SERVFAILs | The upstream is unreachable and `forward-first: no` means there is no cleartext fallback, by design. Check `ss -tn state established '( dport = :853 )'` on the node |
| A site is blocked and the allowlist does not help | It is an upstream block, not a local one. See "Overriding an upstream block" |
| A blocked site gives SERVFAIL rather than NXDOMAIN | Expected for an upstream block on a DNSSEC-signed zone: our validator rejects the forged denial. Confirm with `kdig +tls +cdflag` — NXDOMAIN there means validation is doing it |

```sh
make ssh                                  # get onto the node
journalctl -u dnsdist -u unbound -f       # RAM only, nothing persisted
systemctl start rpz-update.service        # refresh blocklists now
unbound-control list_auth_zones           # what is actually loaded
```

## Costs

Hetzner figures verified against the account's own `/v1/pricing` on 2026-09-27.
**This account is billed in USD**, and a primary IPv4 is charged separately per node.

| | Monthly |
|---|---|
| `cx23` (2 vCPU, 4 GB) in fsn1 / hel1 / nbg1 | $6.49 |
| primary IPv4, per node | $0.60 |
| one node | $7.09 |
| two nodes | $14.18 |
| Route 53 health check, per node per address family | $0.75 |
| **two nodes with failover, as deployed** | **$17.18** |

Traffic is 20 TB included per node, which DNS will not come close to using.

Health checks are billed at the **non-AWS endpoint** rate, because the endpoints are
Hetzner addresses: $0.75/month against $0.50 for an AWS endpoint, and the 50 free
checks apply only to AWS endpoints, so none of these are free. Setting
`dns_health_check_interval = 10` bills as an "optional feature" at a further
$2.00/check — four times the cost of the check, to save 60 seconds of detection.
`dns_health_check_ipv6 = false` halves the $3.00 to $1.50; the trade is in
"Failover" above.

Route 53 query charges are left out of the estimate deliberately:
multivalue-answer answers bill as standard queries at $0.40/million, and at TTL 60 a
handful of clients generate thousands of queries a month, not millions. AWS prices
are list prices from <https://aws.amazon.com/route53/pricing/>, read on 2026-09-27 —
unlike the Hetzner ones they are not read back from the account.

**US locations are a different product line and cost far more.** None of the `cx*`
types are offered in `ash` or `hil`; the cheapest 4 GB type there is `cpx21` at
$37.49/month, over five times the EU price. So a node near US users is not the
one-line change to `var.nodes` that a second EU node is — at that price another
provider is worth comparing.

`make apply` prints the estimate and requires you to type `yes`; `make destroy`
asks twice. Re-check pricing yourself with:

```sh
curl -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/pricing
```

## Backlog

Open work, and what each item blocks, is in [BACKLOG.md](BACKLOG.md). The short
version: there is no availability monitoring at all. Nothing tells you the resolver
is broken — health checks withdraw a dead node, but they do not tell you it died,
and they cannot see a certificate about to expire.

## License

Configuration in this repository is yours to use. Blocklists are Hagezi's, under
[their license](https://github.com/hagezi/dns-blocklists/blob/main/LICENSE).
