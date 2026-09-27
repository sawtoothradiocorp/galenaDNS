# Backlog

Open work, roughly in the order it should matter. Each item says why it exists and
what "done" looks like, because a backlog that only names tasks rots into a list
nobody can act on.

Nothing here is required for the resolver as it runs today, for one operator. Most
of it becomes required the moment anyone else is pointed at it.

---

## 1. External availability monitoring

**Nothing currently tells you the resolver is broken.** There is no alerting of any
kind. Today you would find out when a browser stops loading pages, and if you are
not the one using it at the time, you would not find out at all.

"External" is load-bearing: a monitor running on the node cannot report that the
node is down. It has to run somewhere else.

This does **not** conflict with the no-logging design. Probing your own endpoint
produces no client data — it is your query about your own service. Nothing about
anyone's browsing is involved, and `make audit` would still pass unchanged.

### What to watch, ordered by how quietly it fails

| Check | Why it matters | How |
|---|---|---|
| **Certificate days remaining** | The worst one. Renewal runs unattended via `certbot.timer`. If it fails — expired IAM key, Route 53 permission change, plugin breakage after an upgrade — nothing says so, and ~60 days later every client's TLS handshake fails at once. | `openssl s_client -connect base.dns.swthrc.com:853` and parse `notAfter`. Alert under ~21 days. |
| **Does it answer, per transport** | DoH, DoH3, DoT and DoQ fail independently. dnsdist can be up with one listener broken. | `scripts/test-resolver.sh` already covers all four. It just needs to run on a schedule somewhere else. |
| **Is DNSSEC still validating** | A validator that silently stopped is invisible: everything still resolves, just without protection. | Already in `test-resolver.sh` — bogus must SERVFAIL, good must set AD. |
| **Upstream reachability** | `forward-first: no` means an unreachable Quad9 SERVFAILs *everything*, by design. There is no degraded mode to mask it. | Any successful resolution proves it. A total outage is the signal. |
| **Blocklist freshness** | A feed that stopped updating still resolves fine. Nothing surfaces it. | Age of `/var/lib/unbound/rpz/*.rpz`, or the `rpz-update` timer's last success. |

### Shape of the implementation

You already own the right machine: **mtbaldy** (Hetzner Hillsboro).
It is off-node, already trusted, already has SSH to the resolver, and involves no
third party.

- a systemd timer there running `scripts/test-resolver.sh` against the public name
- plus a certificate-expiry check, which is the single highest-value piece
- alert on failure

**The gap that leaves:** if mtbaldy dies or the timer breaks, silence is
indistinguishable from success. The fix is a **dead man's switch** — the check
pings a URL only when it *passes*, and the service alerts when pings stop. That
covers both "resolver broken" and "monitor broken".

Healthchecks.io has a free tier suitable for this. What it learns is that a host
exists and is up, which the Certificate Transparency log already made public when
the certificate was issued, so it discloses nothing new.

**Done looks like:** the certificate silently failing to renew produces an alert
weeks before clients notice, and killing the timer on mtbaldy also produces one.

**Estimate:** a timer, a check script, a README section. Roughly an afternoon.

---

## 2. A second node

Single node means **total DNS failure**, not degradation. A client with Private DNS
or the `.mobileconfig` installed has no fallback — it presents as "the internet is
broken" with no clue why. This is the strongest argument against pointing anyone
else at it.

Verified against the account's own `/v1/pricing` on 2026-09-27: **+$7.09/month**
($6.49 `cx23` + $0.60 primary IPv4). See README "Costs".

Pick `nbg1` or `hel1`. Both are close enough to `fsn1` that round-robin costs no
noticeable latency, which avoids the multi-continent problem where a European
client gets a distant address a third of the time. US locations are a different and
far more expensive product line — no `cx*` type exists in `ash` or `hil`, and the
cheapest 4 GB option is `cpx21` at $37.49.

Mechanically it is one key in `var.nodes`; the map was built for this.

Prefer **hel1** over nbg1. fsn1 and nbg1 are both in Germany, sharing one legal
system, one national grid and one country's network infrastructure; hel1 is in
Finland at the same price and the same `eu-central` network zone. Given the German
resolver-liability precedent noted in section 3, that is the one axis of diversity
worth buying. The caveat is that Hetzner Online GmbH is a German company either
way, so this diversifies the *server*, not the *operator* — full diversity means a
second provider. The latency cost is ~15-25 ms for central-European clients and
negligible from the US.

### Two nodes is not failover on its own

A second address in the record set gives *distribution*, not failover. DoT and DoH
clients resolve the hostname once, pick an address and hold that connection, so a
client is pinned to one node for the life of the connection rather than alternating
per query. When a node dies, the clients on it fail and retry, and the behaviour
varies by platform — Android will surface "Private DNS server cannot be accessed"
before it recovers.

**Route 53 health checks on TCP/853, attached to the record set**, are what convert
two nodes into real failover: a dead node's address is withdrawn from DNS
automatically. Roughly $0.50-0.75 per check per month, and it overlaps section 1 —
a health check that fires is also a monitoring signal.

### Latency-based routing, once there is a third location

While every node is in `eu-central`, returning both addresses is right. A node on
another continent makes plain round-robin actively harmful: a European client would
get a distant address a third of the time, and stay pinned to it. **Route 53
latency-based routing** keeps the single hostname and returns the nearest node
instead. A small change to `dns.tf`, and the prerequisite for ever putting a node
outside Europe.

---

## 3. Before anyone else is pointed at it

Not code. All of it blocks "lightly advertised", none of it blocks personal use.

- **`max_qps_per_ip = 40` will break NATed groups.** Fine for a household. A
  university, an office or a CGNAT range is thousands of users behind one address,
  and 40 qps will drop their traffic. Raising it weakens the only abuse control
  there is. A real decision, currently made by default.
- **Abuse-handling posture, written down before the first complaint.** Hetzner will
  forward complaints with a deadline. The honest answer — "we retain nothing, so we
  cannot tell you which user did this" — is much better delivered from a prepared
  position than improvised. Confirm Hetzner's tolerance for open resolvers first.
- **DNS tunnelling is the abuse this will actually attract**, and detecting it means
  inspecting query names, which the entire design forbids. dnsdist can match qname
  length and label count inline, per-query, without recording anything — that
  catches crude tunnelling and not a patient adversary. Worth doing; worth not
  overselling.
- **Privacy policy naming a data controller.** IP addresses are personal data under
  GDPR and they transit the dynblock rings. A public EU service plausibly needs
  this, which means attaching a real identity or entity. A personal-exposure
  decision, not a technical one.
- **Legal reading, specific to German hosting.** Sony sued Quad9 in Germany over
  resolving a piracy site and Quad9 lost at first instance — a resolver held liable
  for what it resolves, not for hosting anything. There were appeals; check the
  current status rather than trusting a summary. This is the most underappreciated
  risk of running a public blocking resolver in the EU.
- **No-SLA statement and a sunset policy.** A resolver that vanishes breaks people
  who trusted it.

---

## 4. Smaller, measured, not urgent

- **Rate limiting has never been tested for real.** `make test ARGS=--include-ratelimit`
  reports a false pass from mtbaldy because `rate_limit_exempt_cidrs` defaults to
  `admin_cidr`. Needs one run from another network.
- **Cache headroom.** Steady state is 557 MB across ~895,000 RPZ entries. Caches are
  `256m`/`512m` and could go `512m`/`1024m`. Read README "Memory" first — RSS after
  a blocklist reload reads ~1366 MB because glibc keeps the freed arena, and
  `MemoryMax` acts on RSS, so the cap has to cover the peak.
- **A second upstream operator.** One upstream is a single point of failure that
  `forward-first: no` converts into a hard outage. Several `forward_tls_upstreams`
  from *different* operators would also spread query names so no single provider
  sees the whole stream. Currently all four entries are Quad9.
- **No way to answer "how many people use this."** Counting unique clients means
  retaining something derived from client IPs. Solvable approximately — a
  HyperLogLog or an hourly-reset Bloom filter — but it is a deliberate step away
  from "we retain nothing" and should be decided, not drifted into.
- **Reboot policy.** `unattended-upgrades` patches packages; kernel updates need a
  reboot that nothing currently performs or schedules.
- **Publishing the repo.** GitHub, for discovery next to Hagezi and the dnsdist
  mirrors. Confirm `git log --all -- terraform/terraform.tfstate` is empty first —
  state holds node addresses and resource IDs, and although it is gitignored and was
  never committed, that is worth verifying rather than assuming.
