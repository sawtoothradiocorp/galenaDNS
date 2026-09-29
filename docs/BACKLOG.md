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
- `monitor/galena-probe` on the monitor host every 5 minutes, per node by address: all four
  transports, DNSSEC both ways, blocking, and the certificate on both listeners,
  alerting under 21 days;
- a heartbeat metric from every passing run, with an alarm when it stops — the
  dead man's switch, evaluated by AWS so it survives the monitor host dying.

Everything goes through one SNS topic to `alert_email`, and costs nothing inside
CloudWatch's always-free tier. Healthchecks.io and an Airflow instance on a home server were both considered for the dead man's switch; CloudWatch won because
it needs no new host, no cross-host SSH key and no third party beyond the one
already holding the zone.

Installed on the monitor host on 2026-09-27: first run 14/14 OK, test alert published,
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
| **IPv6 end to end** | The monitor host has no IPv6 route, so the prober checks IPv4 only. The v6 health checks prove TCP/853 and nothing more. | A v6-capable monitor host, or IPv6 on the current one. |
| **A second vantage point** | A failure that affects only some networks — UDP/QUIC through home NAT is the classic, and it is how DoQ and DoH3 fail for real users — is invisible from a datacenter. | An existing scheduler (Airflow) on a home server with a residential connection, running the same checks as a DAG. It currently has no alert channel configured. |

---

## 2. A second node — done

`hel1-a` joined `fsn1-a` on 2026-09-27, for +$7.09/month ($6.49 `cx23` + $0.60
primary IPv4) plus $1.50/month for its two health checks. See README "Costs".

**hel1 rather than nbg1**, because fsn1 and nbg1 are both in Germany — one legal
system, one national grid, one country's network — while hel1 is in Finland at the
same price and in the same `eu-central` network zone. That was chosen while the
German Sony v. Quad9 liability ruling stood; Quad9 has since won on appeal (section
3), but two legal systems remain a better position than one. The caveat stands: Hetzner Online GmbH is German either way, so this
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
  `99d7f49` before touching the servers' `public_net` — the obvious version of this
  change deletes both nodes' addresses, the plan does not show it, and the
  `ignore_changes` that prevents it is load-bearing.

  `delete_protection` is on (`primary_ip_delete_protection`, 2026-09-27), since the
  addresses are now published: a destroy or node removal cannot release an address
  other people typed in. What remains: survival across a replacement is established
  from the provider source, not observed:
  `terraform apply -replace='hcloud_server.node["hel1-a"]'` then `make deploy` would
  prove it, at the cost of one node down for ~10 minutes behind failover.
- **Per-address rate limit — decided for households, 2026-09-27.** One address is
  taken to be a household or small office of up to 50 devices: 50 q/s sustained,
  burst 500 (README "Design choices"). Dynamic blocks and their query ring are off,
  which removed the only place client IPs and query names were recorded together.
  A university or CGNAT range — thousands behind one address — would be throttled;
  serving those means a much larger limit or per-network exemptions, and is a
  separate decision.
- **Abuse-handling posture — written, 2026-09-27: [ABUSE.md](ABUSE.md).** Contact
  abuse@swthrc.com; what these addresses do and do not do on the network; what a
  report can and cannot get; Hetzner's forwarding process from its own Digital
  Services Act page (a "reasonable deadline", a reminder, then a possible IP lock
  until a statement arrives); the common complaints with their honest answers; a
  statement template; how to block a client. Still open:
  - **Hetzner's stance on public encrypted resolvers** could not be found in
    anything Hetzner publishes. The classic objection — an open resolver on 53 as
    an amplifier — does not apply, since 53 is closed, but ask their support before
    advertising rather than learn it from a lock.
  - ~~The 24-hour acknowledgement target~~ — kept: abuse@ is monitored
    (confirmed 2026-09-27). What decides whether complaints are met in time is
    mostly elsewhere, though: whois for the nodes' addresses names Hetzner's abuse
    desk, not ours, so most reports will arrive *forwarded by Hetzner*, to the
    Hetzner account's email, on Hetzner's deadline. **Confirm that address is
    monitored as closely as abuse@.**
- **DNS tunnelling — inline limits in place, 2026-09-27.** Names over 220 bytes and
  NULL/65399 queries are REFUSED, judged one query at a time and never recorded
  (README "Design choices"). That stops the common tools at their defaults and
  nothing patient: a tunnel with short names at a low rate is indistinguishable
  from normal traffic without per-domain counting, which this design refuses, and
  is capped only by the per-address rate limit. Open question: whether 220 bytes
  ever refuses a legitimate antivirus reputation lookup. `make audit` reports each
  rule's match count, which is how to find out.
- **Data controller — named, 2026-09-27:** Sawtooth Radio Corp LLC, in PRIVACY.md
  with the recipients (Hetzner, Quad9, AWS) and what a data-subject request can
  return. IP addresses are personal data under the GDPR: they pass through every
  connection, and the per-address rate counters hold them for 5-15 minutes after an
  address's last query. Still open, and a matter for legal review rather than
  engineering: the **lawful basis** relied on; whether a US-based controller
  serving people in the EU needs an **Article 27 representative** there. Privacy
  requests now go to their own address, dataprotection@ — see below.
- **Sign the Apple configuration profiles — a smaller payoff than it looks,
  researched 2026-09-28.** Signing makes a profile tamper-evident and puts a name
  on the install sheet. It does *not* produce the green "Verified" this item used
  to promise: that badge and its checkmark were removed in iOS 18 and macOS 15
  ([iMazing](https://imazing.com/guides/how-to-sign-apple-configuration-profiles),
  updated 2026-03-25). A current device shows three states instead — `Signed by
  <certificate name>` in plain text when the chain is trusted, a red **Not
  Verified** when it is not, and **Not Signed** for the profiles as they ship
  today. So the gain is an attributable author, not a green tick, and a broken or
  expired signature is *worse* than no signature. It still adds little security:
  the profiles are served over HTTPS and the DNS connection is
  certificate-verified on every query regardless. README "Apple" and the notice
  page both still say "Unverified", which is pre-iOS-18 wording — see what a
  device actually says before rewriting either.
  - **Never sign with the resolver's TLS certificate.** Its key protects every
    DoT/DoH session; copying it off the nodes for a cosmetic gain is a bad trade.
  - **Plan: an Apple Developer ID Application certificate, $99/year.** Chosen
    2026-09-28 by taking apart the closest analogue there is. Mullvad publishes
    encrypted-DNS profiles to strangers exactly as this does, and signs them with
    `Developer ID Application: Mullvad VPN AB`, issued by Apple's Developer ID
    Certification Authority G2, EKU **Code Signing (critical)**, valid five years
    (2023-05 to 2028-05), with that intermediate embedded in the profile itself
    (<https://github.com/mullvad/encrypted-dns-profiles>). The five years are the
    point: a signature has to outlive the installs sitting on it. Two things fall
    out of that certificate. A critical `codeSigning` EKU is plainly accepted by
    the installer, so the claim that Apple requires `emailProtection` on a profile
    signer is wrong — no Apple documentation states an EKU requirement either way.
    And Developer ID is the only code-signing certificate still usable here at all.
  - **Why the other code-signing certificates are out.** Since 2023-06-01 the
    CA/Browser Forum has required code-signing keys to be generated in, and never
    leave, FIPS 140-2 level 2 hardware
    ([DigiCert](https://knowledge.digicert.com/alerts/code-signing-changes-in-2023)),
    so no `openssl smime -sign` can reach one — it would take a USB token, PKCS#11
    and $200-400 a year. Apple issues Developer ID against an ordinary Keychain
    keypair, which is the whole reason a local signing step remains possible.
  - **What enrolling costs beyond the money.** Organization enrollment needs a
    D-U-N-S number for Sawtooth Radio Corp LLC (free, about five business days when
    requested for Apple), a work email on the organization's domain, and a public
    website on it — `sawtoothradiocorp.com` already satisfies the last two.
    **Enroll as the organization, not as an individual.** An individual enrollment
    puts the operator's personal legal name in the certificate's CN, and the CN is
    what the install sheet displays, which would publish on every stranger's phone
    exactly what commit `9f46fa8` stripped out of this repo. What they would read
    is `Signed by Developer ID Application: Sawtooth Radio Corp LLC (TEAMID)`.
    Limits worth knowing: five Developer ID Application certificates per team; if
    the membership lapses, what is already signed keeps working but nothing new
    can be signed; notarization is a Mac-app concept and does not apply to profiles.
  - **The money, stated plainly.** $99/year against $17.18/month deployed is about
    +48% on the annual running cost — $206 to $305 — for something this item itself
    calls cosmetic. That is the argument for enrolling when the service is actually
    advertised and not before, and leaving the profiles unsigned until then.
  - **Let's Encrypt is out**, rejected 2026-09-28, though it was this item's
    fallback. Two independent reasons. Ballot SC-081v3 caps public TLS certificates
    at 200 days from 2026-03-15, 100 days from 2027-03-15 and 47 days from
    2029-03-15
    ([DigiCert](https://www.digicert.com/blog/tls-certificate-lifetimes-will-officially-reduce-to-47-days)),
    so the entire certificate class is being driven toward lifetimes far shorter
    than the installs it would be signing. And the expiry behaviour below means a
    90-day certificate would turn every already-installed profile red four times a
    year, which is worse than shipping them unsigned.
  - **The expiry question, answered — this item had it backwards.** It assumed iOS
    checks the signature only at install time, so a lapsed certificate would affect
    new installs alone. Jamf administrators report the opposite from the field:
    profiles deployed *before* the signing certificate expired show **Unverified**,
    newly installed ones are fine, and nothing stops working — it is cosmetic
    ([Jamf](https://community.jamf.com/t5/jamf-pro/mdm-profile-unverified-signing-certificate-expired/m-p/154587)).
    Still to confirm on a device: whether that also applies to manually installed
    profiles, since every report found is from an MDM fleet.
  - **Free Actalis S/MIME — fallback only.** Under the current S/MIME baseline
    requirements a mailbox-validated certificate's subject is the email address
    alone, so the sheet would read `Signed by dataprotection@swthrc.com`. One year
    of validity, so the red-after-expiry problem returns annually rather than
    quarterly. Whether the installer accepts an `emailProtection`-only EKU is
    untested, though Mullvad's critical `codeSigning` EKU suggests it does not
    filter on EKU at all. Also: actalis.com was unreachable from the operator's
    network on 2026-09-28, and their free flow generates the keypair server-side.
  - **Never sign with a self-signed certificate.** It produces a red **Not
    Verified**, which is worse than the **Not Signed** the profiles carry today.
  - **Mechanics, tested 2026-09-28 against this repo's own DoT profile.** `openssl
    smime -sign -signer cert.pem -inkey key.pem -certfile chain.pem -nodetach
    -outform der` produces a DER profile that macOS's own `security cms -D` parses
    back to the original plist; `security cms -S -N "Developer ID Application:
    ..."` signs straight from the Keychain without exporting the key at all. Embed
    the Developer ID G2 intermediate with `-certfile`, as Mullvad does, rather than
    relying on the device having it. A `make sign-profiles` target writing into
    klix-hq's `public/` would keep the unsigned plist as the source of truth and
    publish the DER beside it; every `make mobileconfig` invalidates the signature,
    so re-signing belongs in the same step.
- **Legal exposure — liability settled, blocking orders live.**
  - *Liability, Germany: resolved in the resolver's favour.* Sony won injunctions
    against Quad9 in Hamburg and Leipzig, holding a resolver liable for what it
    resolves; the Higher Regional Court in Dresden reversed that in December 2023,
    holding a resolver a neutral intermediary, and said the decision was final.
    ([TorrentFreak](https://torrentfreak.com/dns-resolver-quad9-wins-pirate-site-blocking-appeal-against-sony-231208/),
    [Quad9](https://quad9.net/news/blog/quad9-turns-the-sony-case-around-in-dresden/))
  - *Blocking orders: the live risk, and a different kind.* Not "you are liable",
    but "you must stop resolving these names". Since 2024 Paris courts have ordered
    the public resolvers of Google, Cloudflare and Cisco — then Quad9 and the EU's
    own DNS4EU — to block pirate sports-streaming domains, and a Belgian order on
    the same model was upheld, backed by fines of up to €100,000 a day.
    ([CircleID](https://circleid.com/posts/20240618-french-court-orders-google-cloudflare-cisco-to-poison-dns-in-anti-piracy-crackdown),
    [TorrentFreak](https://torrentfreak.com/eu-funded-dns-provider-must-block-pirate-sites-french-court-rules/),
    [TorrentFreak](https://torrentfreak.com/court-upholds-belgian-pirate-dns-blocking-order-opendns-exit-looms/))
  - *What that means here.* Some such blocks reach users anyway, through Quad9.
    A small, unadvertised resolver is an unlikely direct target; advertised in
    France or Belgium, less so. Complying would need a way to block a named list
    of domains, first in the RPZ order and out of the allowlist's reach, quickly —
    **which does not exist yet**. The allowlist zone is the only local zone today.
    Worth building before advertising: a small `legal` zone, versioned in this
    repo, whose history is itself the record of what was blocked and why. Whether
    to publish that list is a transparency decision for the operator.
- **No-SLA and sunset — written, 2026-09-27: [TERMS.md](TERMS.md).** No service
  level, provided as is, acceptable use, and at least 90 days' notice before a
  permanent shutdown, with the service unchanged throughout. Its central
  commitment is about the hostname: after shutdown `base.dns.swthrc.com` points at
  nothing for at least 90 days, and never afterwards at a DNS service run by anyone
  else, nor is it transferred while the operator holds `swthrc.com` — so a device
  nobody reconfigured fails closed instead of sending its DNS to a stranger.
  Narrowed 2026-09-28 from "kept and pointed at nothing" indefinitely: the operator
  may reuse the name for its own purposes after 90 days, which is safe, since only
  someone else's resolver on the name is dangerous.
- **Before any of the docs above are published** — each is a promise the docs
  already make, so it has to be true first:
  - ~~Create `dataprotection@swthrc.com`~~ — done 2026-09-27. Deliberately not
    `privacy@`, which receives Privacy.com account mail.
  - ~~Publish the notice page~~ — live 2026-09-27 at
    <https://sawtoothradiocorp.com/galena-dns> (the klix-hq repo), with the
    service-notice box TERMS.md points to, setup, contacts, and links to these
    documents; the Apple profiles are served alongside with the content type iOS
    needs to offer installation. The homepage links to it. Checked on a phone by
    the operator, 2026-09-27.
  - ~~`swthrc.com` from lapsing~~ — auto-renew on (expiry 2027-08-01) and the
    transfer lock enabled 2026-09-27 (`clientTransferProhibited`);
    `sawtoothradiocorp.com` already had both.
  - **Legal review** — deferred until growth warrants it (operator's call,
    2026-09-28); see "Legal exposure grows with users" below for the trigger and
    the questions to bring. TERMS.md and PRIVACY.md are live without it, so their
    warranty, liability and jurisdiction wording stands unreviewed until then.
- **Legal exposure grows with users — the trigger for a lawyer.** Exposure
  scales with how many people use the service and where they are, so the review
  is tied to growth rather than a date. The resolver cannot count users — by
  design it keeps nothing that would let it — but dnsdist's aggregate `queries`
  counter gives a rate. One measured anchor: fsn1-a, carrying roughly one
  household plus the prober, averaged **0.73 q/s** over its first 13.6 hours.
  Treating that as ~0.7 q/s per household — a thin sample, so read every figure
  below as an order of magnitude:

  | Scale (households) | Sustained, both nodes | Expected legal exposure |
  |---|---|---|
  | up to a few hundred | up to ~200 q/s | occasional abuse complaints via Hetzner; rare GDPR requests; blocking orders and law-enforcement requests effectively nil |
  | ~1,000–10,000 | ~700–7,000 q/s | regular abuse complaints; first GDPR requests; appearing on public resolver lists, where rightsholders notice a resolver popular in France or Belgium; law-enforcement requests still unlikely |
  | ~10,000–100,000 | ~7,000–70,000 q/s | blocking orders plausible with a real French/Belgian/Italian share; occasional preservation or data requests; a lawyer on call |
  | 100,000+ | 70,000 q/s+ | a notable public resolver — all of the above, and two small nodes are not enough |

  **Triggers.** Sustained ~700 q/s across both nodes (~1,000 households): schedule
  the review, and build the `legal` zone if it does not exist yet. ~7,000 q/s
  (~10,000 households): have counsel reachable, and talk to Quad9 — that is also
  roughly where every query arriving from two addresses starts to look to Quad9
  like one very heavy source, so the legal and the technical pressure arrive
  together. Measuring it is two readings of the counter a minute apart per node,
  as was done on 2026-09-27; turning that into a CloudWatch metric the prober
  publishes would make the trigger watch itself.

  **Questions to bring:**
  - Is a public DNS resolver an "electronic communication service" under US law
    (the Stored Communications Act, the CLOUD Act) — and so what process can reach
    it, and what can it be compelled to produce?
  - Exposure to pen-register and trap-and-trace orders, which can compel a
    provider to *start* collecting addressing information, possibly gagged. Is
    DNS query data "addressing information" for that purpose?
  - A US demand for EU users' data against GDPR Article 48, which restricts
    transfers to foreign authorities without a treaty basis: how would that
    conflict play out, and what should the response procedure be?
  - A warrant canary: worth publishing, given it is legally untested in the US?
  - TERMS.md: the warranty and liability wording, and whether to name a
    governing law and venue (deliberately absent).
  - GDPR: the lawful basis relied on, and whether an Article 27 EU representative
    is required for a US controller serving people in the EU.
  - Blocking orders: how to respond to one from France or Belgium, and whether to
    publish what the `legal` zone blocks.
  - Whether, at scale, a separate non-US entity should operate the service — the
    only structure that takes the operator itself out of direct US reach.

---

## 4. Smaller, measured, not urgent

- **Pad answers back to the client — when dnsdist 2.2.0 is stable.** An encrypted
  answer still has a size. A blocked name comes back as a few dozen bytes and a
  normal answer is larger, and the set of sizes in one page load is enough to
  guess many popular sites. Rounding every answer up to one of a few lengths
  blunts that. The server cannot change the size of the query the client already
  sent, and it cannot hide how many lookups a page makes or when.

  Queries toward Quad9 are already padded. unbound's default `pad-queries: yes`
  (block size 128) is live on both nodes, checked 2026-09-28, so the name's
  length does not show on that uplink. `pad-responses` is on too and does nothing
  for clients: unbound only pads answers to queries it received over TLS, and
  dnsdist has already unwrapped those onto plain DNS on loopback.

  The padding belongs in dnsdist, on the way back to the client. `padResponses`
  does it for DoT, DoH, DoQ and DoH3, rounding every response to a multiple of
  468 bytes (RFC 8467), including answers the client did not ask to have padded.
  It is a 2.2 feature. As of 2026-09-28 the newest stable package is 2.1.2, which
  is what the nodes run (`trixie-dnsdist-21`); 2.2.0 exists only as an alpha.
  Rewriting the EDNS OPT record in Lua on 2.1 would be the same feature,
  maintained here, on the path every answer takes.

  **Done:** repo.powerdns.com is publishing a stable 2.2 — a release, not an
  alpha or a release candidate. Point `node/bootstrap.sh` at `dnsdist-22`, set
  `padResponses = true` on all four listener families in
  `node/dnsdist/dnsdist.conf.tmpl`, and confirm with `kdig` that an ordinary
  answer and a blocked name both come back at a multiple of 468 bytes, on a
  cache hit as well as a miss.

- **Rate limiting — tested for real, 2026-09-27.** The old test could never have
  found a limit: 200 sequential kdig calls, each a new TLS handshake, run well under
  10 q/s from far away. It now pipelines queries over one DoT connection. Against
  the old 40/no-burst config, from a non-exempt address, a 300-query household
  burst got 40 answers and a closed connection. `rate_limit_exempt_cidrs` still
  defaults to `admin_cidr`, so run it from anywhere else.
- **Active DoT connections are closed after ~11 seconds — unexplained.** Found
  2026-09-28 while verifying the connection-cap fix. One DoT connection to hel1-a,
  sending `example.com` repeatedly: at a 0.2 s gap dnsdist closed it after 20
  answers and 11.0 s; at 1 s, after 8 answers and 10.9 s; at 3 s, after 1 answer
  and 4.1 s. The last is the documented `setTCPRecvTimeout` default of 2 s and is
  normal — clients reconnect when they next need to. The first two are not: the
  connection was busy, `setMaxTCPConnectionDuration` is 600, and nothing in the
  config or the docs gives ~10 s. Same from the monitor host, so it is server-side; same
  with 1 connection or 40, so it is not the per-client cap. Cost if real: a busy
  client reconnects every ~10 s, with TLS session resumption softening each
  reconnect. To do: reproduce against a stock dnsdist with only `addTLSLocal`,
  then read dnsdist's incoming-TCP handling, before changing anything.
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
- **Publishing the repo — done, 2026-09-27.** Public at
  <https://gitlab.com/sawtooth-radio-corp/galenaDNS>, push-mirrored by GitLab to
  <https://github.com/sawtoothradiocorp/galenaDNS> through a write deploy key (no
  expiry, scoped to that one repo). MIT licensed. Before the first push the history
  was rewritten — the only safe moment to do it — to remove a home address and the
  admin host's address from commit messages and old file versions, and a laptop
  hostname from the author field; then every blob in it was scanned for keys and
  tokens (none; the only 64-character strings are checksums). tfstate and tfvars
  were never committed. The node addresses were delete-protected first, since the
  docs publish them.
