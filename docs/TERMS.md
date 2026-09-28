# Terms of use

`base.dns.swthrc.com` is a free public DNS resolver operated by **Sawtooth Radio
Corp LLC**, a Colorado limited liability company. Using it means accepting these
terms. They are written to be read, so they say plainly what is and is not being
offered — starting with the most important part: **this is a best-effort service
with no guarantee that it will be available, and it may one day end.**

What the service keeps about you is in [PRIVACY.md](PRIVACY.md). How to report
abuse is in [ABUSE.md](ABUSE.md).

---

## No service level

There is **no service level agreement**: no uptime target, no response-time
promise, no support commitment and no compensation for downtime.

The service is built to stay up — two nodes in two countries, automatic failover
when one stops answering, and monitoring that alerts the operator — but outages
will happen, maintenance can happen without notice, and the operator is one small
company, not a network operations centre.

**Plan for it to be unavailable.** Every setup the README documents is a strict
one, chosen so that your queries never silently go somewhere else — which also
means an outage is felt:

- **Android Private DNS, the iOS/macOS profiles, Windows and systemd-resolved** have
  no fallback. If the resolver is unreachable, nothing resolves and the device looks
  offline.
- **Firefox on Max Protection** shows an error page offering to use your normal DNS
  instead; **Chrome and Edge with a custom provider** simply fail to load pages.

Know how to turn the setting off, and do not set it up on a device someone depends
on without telling them how. If you would rather keep working through an outage at
the cost of the filtering and privacy, Firefox's *Increased Protection* level falls
back to your normal DNS automatically.

## Provided as is

The service is provided **as is and as available, without warranties of any
kind**, express or implied — including that it will be uninterrupted, error-free,
or suitable for any particular purpose. To the extent the law allows, Sawtooth
Radio Corp LLC is **not liable for any loss or damage** arising from using the
service, from its being unavailable, or from its answers.

In particular:

- **Filtering is not a security product.** The resolver blocks domains that
  third-party lists and its upstream consider ads, trackers or malware. Those
  lists are incomplete and sometimes wrong: some harmful sites will resolve, and
  some legitimate ones will be blocked. Use it alongside real protections, never
  instead of them.
- **Answers come from others.** Names are resolved through an upstream resolver
  (Quad9) and validated with DNSSEC where the domain supports it. The operator
  does not vouch for what any domain points to.

## Acceptable use

Anyone may use the service, free of charge, for lawful purposes. Do not use it to:

- flood it, test it for load, or try to degrade it for others;
- tunnel data through DNS, or carry command-and-control traffic;
- attack, probe or disrupt any other system;
- do anything unlawful where you are or where the service runs.

The service applies limits to everyone, automatically: each client address may
send about **50 queries a second** (up to 500 at once), which suits a household or
a small office of up to about 50 devices. Some query shapes associated with DNS
tunnelling are refused. Larger networks sharing one address — a campus, an ISP's
shared address pool — will hit those limits; get in touch before pointing one at
the service.

The operator may **limit, refuse or block** any client address or network, at any
time and without notice, to protect the service or others.

## Changes

The operator may change the service at any time — blocklists, limits, locations,
the upstream resolver, supported protocols — and may change these terms. The
current terms are the ones in this document; its history records every change.
Changes that affect what is kept about you are made in PRIVACY.md first, and never
silently.

---

## Sunset: 90 days' notice

If the service is ever going to shut down for good, the operator will give **at
least 90 days' notice**, stating the date, before it stops answering.

During those 90 days:

- **It keeps running as it does now**, with the same privacy properties. Nothing is
  added to the service to wind it down — no logging, no redirection, no changed
  upstream.
- **The notice stays up** at
  [sawtoothradiocorp.com/galena-dns](https://sawtoothradiocorp.com/galena-dns), so
  anyone setting the service up during that time sees it first.

On the shutdown date:

- **The servers are destroyed**, and with them their keys. There is no data to hand
  over or delete, because none is kept.
- **The hostname is kept, and pointed at nothing.** `base.dns.swthrc.com` stays
  registered to the operator and is never reassigned to another service or
  resolver. Devices still configured with it will fail — they cannot resolve — but
  they fail *closed*: nobody else can later take over the name, obtain a
  certificate for it and quietly receive their traffic. That is the risk with any
  resolver that simply lets its domain lapse, and this commitment is the answer
  to it.
- **The IP addresses go back to Hetzner** and may later belong to someone else.
  Clients that verify the resolver's certificate — every setup this service
  documents — will refuse to talk to whoever gets them, because only the operator
  can obtain a certificate for the name.

**The one exception is an end the operator does not control**: a court order, the
hosting provider ending the service, a security emergency that makes continuing
unsafe, or the operator ceasing to exist. Then the notice will be as long as the
circumstances allow, and the hostname commitment still stands for as long as the
operator exists to keep it.
