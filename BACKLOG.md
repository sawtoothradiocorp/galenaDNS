# Backlog

Open work, roughly in the order it should matter. Each item says why it exists and
what "done" looks like, because a backlog that only names tasks rots into a list
nobody can act on.

Nothing here is required for the resolver as it runs today, for one operator. Most
of it becomes required the moment anyone else is pointed at it.

---

## 1. External availability monitoring — live

Until 2026-09-27 nothing told you the resolver was broken, and failover made that
worse: a dead node is withdrawn, clients move to the survivor, and nothing anywhere
says a node died. README "Monitoring" describes what exists now:

- a CloudWatch alarm on each of the four Route 53 health checks;
- `monitor/galena-probe` on mtbaldy every 5 minutes, per node by address: all four
  transports, DNSSEC both ways, blocking, and the certificate on both listeners,
  alerting under 21 days;
- a heartbeat metric from every passing run, with an alarm when it stops — the
  dead man's switch, evaluated by AWS so it survives mtbaldy dying.

Everything goes through one SNS topic to `alert_email`, and costs nothing inside
CloudWatch's always-free tier. Healthchecks.io and the Airflow instance on
dollarmtn were both considered for the dead man's switch; CloudWatch won because
it needs no new host, no cross-host SSH key and no third party beyond the one
already holding the zone.

Installed on mtbaldy on 2026-09-27: first run 14/14 OK, test alert published,
heartbeat in CloudWatch, the heartbeat alarm cleared to OK, all four node alarms OK.

**Fire drill, 2026-09-27: passed.** dnsdist stopped on `hel1-a` for 6m11s while
`fsn1-a` was checked for DoT every 20 seconds as a safety stop (it never failed):

| From stop | Event |
|---|---|
| +1:09 | first Route 53 checkers fail |
| +1:39 | 0/16 healthy on both families |
| +2:09 / +2:39 | `hel1-a` gone from Google / Cloudflare answers |
| ~+1 and ~+6 | two prober runs record FAIL, publish no heartbeat |
| +4:43 | both `hel1-a` node alarms fire (CloudWatch history: 20:18:01-02 UTC) |
| +6:11 | dnsdist started |
| +7:48 | 16/16 healthy again, both families |
| +8:16 / +8:46 | back in Google / Cloudflare answers |
| +9:43 | both alarms clear (20:23:01-02 UTC) |
| ~+11 | prober run passes; heartbeat resumes |

Alarm times are from CloudWatch's own history; the rest were observed by polling
every 20 seconds, so each is accurate to within that. The heartbeat gap was 15
minutes, under the heartbeat alarm's 20, so that alarm rightly
stayed quiet — for an outage this short the prober's own FAIL email is the alert.
Clients were never without a node. The drill also found a bug: `/etc/galena-probe`
was installed `0750 root:galena-probe`, so `make monitor-check` could not read
`probe.env` and printed nothing. Fixed in install.sh.

### Still not covered

| Gap | Why it matters | Shape of a fix |
|---|---|---|
| **Blocklist freshness** | A feed that stopped updating still blocks yesterday's list; nothing surfaces it. | Needs node access the prober lacks. Cheapest: `rpz-update.sh` publishes its own success metric, alarmed on absence — but that puts an AWS key on the nodes, which today hold only the TXT-only ACME key. Decide before building. |
| **IPv6 end to end** | mtbaldy has no IPv6 route, so the prober checks IPv4 only. The v6 health checks prove TCP/853 and nothing more. | A v6-capable monitor host, or IPv6 on mtbaldy. |
| **A second vantage point** | A failure that affects only some networks — UDP/QUIC through home NAT is the classic, and it is how DoQ and DoH3 fail for real users — is invisible from a datacenter. | The Airflow instance on dollarmtn, on a residential connection, running the same checks as a DAG. It lives in the separate `galena-smt` repo and currently has no alert channel configured. |

---

## 2. A second node — done

`hel1-a` joined `fsn1-a` on 2026-09-27, for +$7.09/month ($6.49 `cx23` + $0.60
primary IPv4) plus $1.50/month for its two health checks. See README "Costs".

**hel1 rather than nbg1**, because fsn1 and nbg1 are both in Germany — one legal
system, one national grid, one country's network — while hel1 is in Finland at the
same price and in the same `eu-central` network zone. Given the German
resolver-liability precedent in section 3, that was the one axis of diversity worth
buying. The caveat stands: Hetzner Online GmbH is German either way, so this
diversifies the *server*, not the *operator*; full diversity means a second
provider. US locations are a different and far more expensive product line — no
`cx*` type exists in `ash` or `hil`, and the cheapest 4 GB option is `cpx21` at
$37.49.

### Two nodes is not failover on its own — done

A second address in the record set gives *distribution*, not failover. DoT and DoH
clients resolve the hostname once, pick an address and hold that connection, so a
client is pinned to one node for the life of the connection rather than alternating
per query. When a node dies, the clients on it fail and retry, and the behaviour
varies by platform — Android will surface "Private DNS server cannot be accessed"
before it recovers.

**Done.** `terraform/dns.tf` now gives each node its own record set under a
multivalue-answer routing policy with a Route 53 health check attached — TCP/853,
30s interval, 3 failures — so a dead node's address is withdrawn automatically.
`dns_record_ttl` dropped to 60, which puts worst-case client recovery at ~150s. Four
checks (two nodes × two address families) at $0.75 each, so $3.00/month; `make
nodes` prints the live configuration and `make apply` includes it in the estimate.
See README "Failover".

**What it does not cover, which is why section 1 exists.** A TCP check proves the
port accepts connections. It cannot see an expired certificate (no TLS handshake,
and expiry hits both nodes at once anyway), a dead unbound behind a live dnsdist
answering SERVFAIL, or a broken DoH/DoH3/DoQ listener, and it *withdraws* a node
without *telling* anyone. Section 1's prober and alarms cover all of that.

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

- **Stable addresses — done, one step short of advertisable.** The four existing
  Primary IPs were imported into `terraform/primary_ips.tf` with `auto_delete =
  false` on 2026-09-27: same addresses, no downtime, no added cost. Read commit
  `278d84c` before touching the servers' `public_net` — the obvious version of this
  change deletes both nodes' addresses, the plan does not show it, and the
  `ignore_changes` that prevents it is load-bearing.

  Two things remain. `delete_protection` is off, because the operator is the only
  IP-configured client; turn it on before publishing IP-based setup, so a destroy or
  node removal cannot release an address other people typed in. And survival across
  a replacement is established from the provider source, not observed:
  `terraform apply -replace='hcloud_server.node["hel1-a"]'` then `make deploy` would
  prove it, at the cost of one node down for ~10 minutes behind failover.
- **Per-address rate limit — decided for households, 2026-09-27.** One address is
  taken to be a household or small office of up to 50 devices: 50 q/s sustained,
  burst 500 (README "Design choices"). Dynamic blocks and their query ring are off,
  which removed the only place client IPs and query names were recorded together.
  A university or CGNAT range — thousands behind one address — would be throttled;
  serving those means a much larger limit or per-network exemptions, and is a
  separate decision.
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
  GDPR: they pass through every connection, and the per-address rate counters
  hold them for 5-15 minutes after an address's last query. A public EU service plausibly needs
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

- **Rate limiting — tested for real, 2026-09-27.** The old test could never have
  found a limit: 200 sequential kdig calls, each a new TLS handshake, run well under
  10 q/s from far away. It now pipelines queries over one DoT connection. Against
  the old 40/no-burst config, from a non-exempt address, a 300-query household
  burst got 40 answers and a closed connection. `rate_limit_exempt_cidrs` still
  defaults to `admin_cidr`, so run it from anywhere else.
- **Failover is verified in the mechanism, not in the client.** Both directions were
  observed for real during the deploy that introduced it: `hel1-a` existed before it
  was deployed, so its checks read 0/16 healthy and Route 53 dropped its address from
  the record set on its own; once dnsdist started, all four checks went 16/16 and both
  addresses came back, in varying order, from Google, Cloudflare and Quad9. Nothing
  was simulated.

  What is *not* tested is the part clients actually experience — killing a node with
  live DoT and DoH connections on it and measuring how each platform behaves through
  the ~150s window. Android is the one to watch: it surfaces "Private DNS server
  cannot be accessed" and its retry behaviour is its own, not DNS's.
  `hcloud server poweroff galena-dns-hel1-a` is the test. The reason it has not been
  run is that it needs a client pinned to that specific node, which round-robin makes
  awkward to arrange deliberately.
- **`make test` does not assert the record shape.** It tests each node by address, so
  it would pass identically if the health checks were detached, the routing policy
  reverted to a plain multi-value set, or a node were missing from DNS entirely — the
  failover configuration is checked by nothing. A `dig` of the hostname compared
  against `terraform output nodes` would catch all three.
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
