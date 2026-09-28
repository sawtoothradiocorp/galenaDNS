# Abuse

`base.dns.swthrc.com` is a public, encrypted DNS resolver operated by
**Sawtooth Radio Corp LLC**, a Colorado limited liability company.

**Report abuse to [abuse@swthrc.com](mailto:abuse@swthrc.com).**

This page says, before anyone asks, what a report can and cannot get: what the
resolver is, what its addresses do on the network, what it keeps, and what the
operator can actually do about a complaint. The short version is that it keeps
nothing that identifies a user, so it can stop things going forward but cannot
say who did something in the past — and that is by design, not by oversight.

---

## For reporters

### What the service is

A DNS resolver: clients ask it for the address of a name, and it answers. It
speaks only DNS-over-HTTPS, DNS-over-TLS and DNS-over-QUIC (ports 443 and 853).
It hosts no websites, stores no files, sends no email and carries no traffic
other than DNS. Blocking of ads, trackers and malware domains is applied to every
answer.

Its addresses:

| Node | IPv4 | IPv6 | Location |
|---|---|---|---|
| fsn1-a | `2.28.3.17` | `2a01:4f8:c012:b8df::1` | Falkenstein, Germany |
| hel1-a | `46.62.237.108` | `2a01:4f9:c014:67fb::1` | Helsinki, Finland |

Both reverse-resolve to `base.dns.swthrc.com`, and are hosted by Hetzner.

### What these addresses do on the network

This list is what to compare a report against, because most complaints about a
resolver turn out to describe something it does not do.

- **Inbound:** encrypted DNS on 443 and 853 from anyone; SSH from one
  administrative address. **Port 53 is closed** — no plaintext DNS is answered
  from outside — so these addresses **cannot be used as DNS amplifiers**. DoT
  and DoH run over TCP and answer nothing before the handshake completes. DoQ runs
  over QUIC, which caps what a server may send an unverified address at three
  times what it received (RFC 9000) — far below what makes an amplifier worth
  abusing, and nowhere near plaintext DNS's tens of times.
- **Outbound:** DNS-over-TLS to Quad9 (`dns.quad9.net`, port 853), which resolves
  every query on the nodes' behalf; HTTPS to Let's Encrypt and AWS Route 53 (the
  certificate), to jsDelivr (blocklist downloads) and to Debian and PowerDNS
  package mirrors; and network time synchronisation.
- **Not outbound: DNS queries to your servers.** The nodes do not resolve names
  themselves. If your authoritative name server logged queries, they came from
  Quad9's addresses, not these. Seeing one of the addresses above querying your
  authoritative server directly would itself be worth reporting.

### What we keep, and therefore cannot give you

**Nothing that ties a query to a person or an address.** Queries are answered and
forgotten; no query log exists on disk or in memory, and no client address is ever
recorded together with a name looked up. [PRIVACY.md](PRIVACY.md) lists exactly
what does exist, and `make audit` verifies it on the running servers.

So we **cannot** tell you:

- which user looked up a particular name, or when;
- what a particular client address looked up;
- whether a particular person used the service at all.

A **preservation request** does not change this: there is nothing retained to
preserve. We will answer such requests promptly and say so plainly, rather than
leave them unanswered.

### What we can do

- **Confirm or rule out** that traffic you observed could have come from these
  addresses, given the list above.
- **Refuse or block** a specific client address or network going forward, if it
  is using the resolver to cause harm.
- **Tighten limits** that already apply to everyone: each client address is held
  to 50 queries per second (500 at once), and very long query names and the
  NULL record type — the signatures of DNS tunnelling — are refused.
- **Pass a malicious domain on to Quad9**, whose filtering blocks it for every
  Quad9 user, not only ours.

### What to include

- the address or addresses involved, and whether they were the source or the
  destination of what you saw;
- timestamps, **in UTC**, and the protocol and ports;
- what happened, and any evidence you can share — logs lines, headers, samples.

We aim to acknowledge reports within **24 hours**.

---

## For the operator

### When Hetzner forwards a complaint

Hetzner's process, from its own [Digital Services Act
page](https://www.hetzner.com/legal/digital-services-act/): the complaint is
forwarded, a response is requested through the customer account by a
**"reasonable deadline"** (the notice states it; Hetzner publishes no fixed
figure), an automated reminder follows if none arrives, and after the deadline
and a manual review **the IP address can be locked** until a statement is
submitted. A locked address is a node out of service — failover will cover it,
but the monitoring alert will not say why.

So: **answer every forwarded complaint before its deadline, even when the
answer is "this is not something a resolver does."** The statement is what keeps
the address unlocked.

1. Read the complaint against "What these addresses do" above. Most fall into one
   of the patterns below.
2. Check whether anything changed: `make audit` (port 53 closed, no unexpected
   outbound connections), `make test`, and the tunnelling counts in audit section
   5.
3. If there is a real abuser, act on the address or network — see "Blocking a
   client" below — and deploy.
4. Submit the statement in the Hetzner customer account.

### Common complaints and the honest answer

| Complaint | What it usually is | Answer |
|---|---|---|
| "Your IP is an open resolver / DNS amplification" | A scanner that found 443/853 open, or a report generated by address range | Port 53 is closed from outside; the encrypted transports require a handshake and cannot amplify. Offer the test: `dig @<address> example.com` times out. |
| "Your IP is scanning / attacking us" | Almost never this service: its only outbound traffic is to the destinations listed above | Compare destinations and ports. If the target is not Quad9, Let's Encrypt, AWS, jsDelivr, a package mirror or a time server, investigate the node — it would be a real incident. |
| "Your IP queried our name server" | Misattribution: the nodes forward everything to Quad9 | The nodes send no queries to authoritative servers; `make audit` checks that authoritative servers see Quad9, not us. |
| "A user of your service did X" (copyright, harassment, fraud) | Someone used the resolver, as millions use any resolver | We host no content and keep no record of who looked up what. We can block a domain or a client going forward, not identify one. |
| "Your resolver resolves a malicious domain" | A domain no feed has caught yet | Report it to Quad9; consider a local block. |

### Statement template

> This address belongs to a public DNS-over-HTTPS/TLS/QUIC resolver operated by
> Sawtooth Radio Corp LLC. It hosts no content and sends no traffic other than DNS
> to its upstream resolver (Quad9) and HTTPS to certificate, package and
> blocklist services. Plaintext DNS (port 53) is closed, so it cannot be used for
> amplification. [What was checked, and what it showed.] [Any action taken.] The
> service keeps no query logs and no record of which client asked for which name,
> so it cannot identify an individual user. Contact: abuse@swthrc.com.

### Blocking a client

There is no standing blocklist of clients. To refuse one address or network, add a
rule to `node/dnsdist/dnsdist.conf.tmpl` ahead of the exemption, for example:

```lua
-- NetmaskGroupRule takes a list of networks directly (dnsdist 1.9+).
addAction(NetmaskGroupRule({ "203.0.113.0/24" }), RCodeAction(DNSRCode.REFUSED),
  { name = "abuse-block-<ticket>" })
```

then `make deploy`. REFUSED rather than a drop: a drop on DoT closes the whole
connection, and a blocked client retrying against a closed door costs more than a
refusal. Record why and when in the commit message, since nothing on the node
will.

### Legal requests

Law enforcement and court requests get the same answer as everyone else: there is
nothing retained to hand over about the past. A lawful order to begin logging is a
different matter, outside anything this repository can decide; PRIVACY.md says so
under "Legal compulsion".
