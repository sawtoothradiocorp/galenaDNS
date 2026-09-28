# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

variable "domain" {
  description = "Public hostname clients will use, e.g. dns.example.com. The TLS certificate is issued for this name and it must match the SNI/ServerName your clients send."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain))
    error_message = "domain must be a bare lowercase FQDN with no scheme, port or trailing dot (e.g. dns.example.com)."
  }
}

variable "project_name" {
  description = "Prefix for Hetzner resource names and labels."
  type        = string
  default     = "galena-dns"
}

# ---------------------------------------------------------------------------
# DNS records (AWS Route 53)
# ---------------------------------------------------------------------------

variable "manage_dns_records" {
  description = "Create the A/AAAA records for var.domain in Route 53, and the health checks behind failover. When true, plan and apply need AWS credentials with Route 53 record and health-check access — aws_profile, or the standard credential chain. The node's TXT-only ACME key is NOT enough. Set false to manage the records yourself."
  type        = bool
  default     = true
}

variable "route53_zone_name" {
  description = "Hosted zone holding var.domain, e.g. swthrc.com. Leave empty to derive it as the last two labels of var.domain; set it explicitly for multi-part public suffixes such as example.co.uk."
  type        = string
  default     = ""
}

variable "dns_record_ttl" {
  description = <<-EOT
    TTL for the resolver's A/AAAA records. Kept short so a node can be replaced
    without clients caching a dead address for long.

    With enable_dns_failover on, this is the second half of the recovery time and
    the half Route 53 cannot shorten for you. Route 53 withdraws a dead node's
    address within dns_health_check_interval * dns_health_check_failure_threshold
    seconds, but every resolver that already answered from cache keeps handing out
    the dead address for up to another TTL. 60 makes the total under two minutes;
    300 makes it over six.
  EOT
  type        = number
  default     = 300

  validation {
    condition     = var.dns_record_ttl >= 60 && var.dns_record_ttl <= 86400
    error_message = "dns_record_ttl must be between 60 and 86400 seconds."
  }
}

# ---------------------------------------------------------------------------
# Failover
# ---------------------------------------------------------------------------
# Two nodes in one record set give DISTRIBUTION, not failover. A DoT or DoH client
# resolves the hostname once, picks one address and holds that connection, so it is
# pinned to a single node rather than alternating per query. When that node dies the
# client sees errors until it retries, and on Android it surfaces as "Private DNS
# server cannot be accessed" first.
#
# Health checks attached to the record set are what close that gap: the dead node's
# address stops being returned at all. See dns.tf for exactly what a TCP check on
# 853 does and does not prove.

variable "enable_dns_failover" {
  description = <<-EOT
    Attach Route 53 health checks to the resolver's record sets so a node that
    stops answering on tcp/853 is withdrawn from DNS automatically.

    Billable, and the reason this is a variable rather than always-on: $0.75 per
    check per month (non-AWS endpoint list price, checked 2026-09-27), which is one
    check per node, doubled if dns_health_check_ipv6 is on. `make apply` folds it
    into the printed estimate before you confirm.

    Ignored with a single node — Route 53 returns every value when all of them are
    unhealthy, so one health-checked node behaves identically to an unchecked one.
    Also ignored when manage_dns_records is false, since nothing Terraform owns
    would consult the check.
  EOT
  type        = bool
  default     = true
}

variable "dns_health_check_ipv6" {
  description = <<-EOT
    Health-check each node's IPv6 address as well as its IPv4 one, and point the
    AAAA record at the v6 check. Doubles the health-check cost.

    On by default because the two families fail independently: a listener that
    binds 0.0.0.0 but not [::], a wrong ip6 nftables rule, or a lost /64 route
    leaves IPv4 green while v6-only clients — a phone on a mobile network — get a
    node that cannot answer them. Set false to halve the bill and accept that.

    With this off, the AAAA record uses the IPv4 check: "the node is up" is a
    better approximation for it than no check at all.
  EOT
  type        = bool
  default     = true
}

variable "dns_health_check_port" {
  description = "TCP port the health check connects to. 853 is DoT, which every node must serve; 443 (DoH) would do equally well. The check only completes a TCP handshake, so the port choice is about which listener you want to prove is up."
  type        = number
  default     = 853

  validation {
    condition     = var.dns_health_check_port == 853 || var.dns_health_check_port == 443
    error_message = "dns_health_check_port must be 853 (DoT) or 443 (DoH) — the only TCP ports this resolver listens on."
  }
}

variable "dns_health_check_interval" {
  description = <<-EOT
    Seconds between health checks, from each of Route 53's 16 checkers (two in
    each of 8 AWS regions).
    Route 53 permits only 30 or 10.

    10 is a billable "optional feature" at $2.00/month per check on a non-AWS
    endpoint — nearly four times the cost of the check itself — to save 60 seconds
    of detection time. Immutable: changing it replaces the check, which changes its
    ID, which updates the record pointing at it.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.dns_health_check_interval == 30 || var.dns_health_check_interval == 10
    error_message = "dns_health_check_interval must be 30 or 10 (Route 53 allows no other value). 10 is billed as an optional feature."
  }
}

variable "dns_health_check_failure_threshold" {
  description = <<-EOT
    Consecutive failed rounds before a node is considered down. Detection takes
    roughly this many times dns_health_check_interval seconds.

    3 rather than 1 because the alternative is flapping: a single slow round trip
    from a checker region would withdraw a healthy node, and every client pinned to
    it would reconnect for nothing. Route 53 already requires agreement across
    checker regions within one round, so this guards against time, not geography.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.dns_health_check_failure_threshold >= 1 && var.dns_health_check_failure_threshold <= 10
    error_message = "dns_health_check_failure_threshold must be between 1 and 10."
  }
}

# ---------------------------------------------------------------------------
# Alerting
# ---------------------------------------------------------------------------

variable "alert_email" {
  description = <<-EOT
    Where alerts go: node health-check failures, the external prober's findings,
    and the prober going silent. Empty disables monitoring.tf entirely.

    AWS emails a confirmation link on first apply, and nothing is delivered until
    it is clicked. See terraform/monitoring.tf.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be an email address, or empty to disable alerting."
  }
}

variable "monitor_host" {
  description = "SSH destination of the always-on machine that runs the external prober (monitor/). It must not be a resolver node: a monitor on the node cannot report the node down. Used by the monitor-* Makefile targets and in alarm text."
  type        = string
  default     = "mtbaldy"
}

variable "aws_region" {
  description = "Region for the AWS provider. Route 53 is global, but the provider requires one."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS profile for Terraform to use, e.g. an SSO profile. Leave empty to use AWS_PROFILE or the standard credential chain. When set it takes precedence over AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY in the environment, so the ACME key exported for `make deploy` does not interfere. Terraform needs Route 53 record and health-check access; this is separate from the long-lived TXT-only key the node uses for ACME renewal."
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------------

variable "nodes" {
  description = <<-EOT
    Map of node key => placement. A map (not count) so that adding a second
    location later does not renumber or recreate the existing node.

    Add a second location by adding a key:
      nodes = {
        fsn1-a = { location = "fsn1" }
        hel1-a = { location = "hel1" }
      }
  EOT
  type = map(object({
    location    = string
    server_type = optional(string, "cx23")
  }))
  default = {
    fsn1-a = { location = "fsn1" }
  }

  validation {
    condition     = length(var.nodes) > 0
    error_message = "At least one node must be defined."
  }

  validation {
    condition = alltrue([
      for n in var.nodes : contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], n.location)
    ])
    error_message = "location must be one of: fsn1, nbg1, hel1 (EU), ash, hil (US), sin (APAC)."
  }

  # CAX is Ampere ARM64 and is only built out in the EU locations. Catching this
  # here turns a confusing API error into a readable one.
  validation {
    condition = alltrue([
      for n in var.nodes :
      !startswith(n.server_type, "cax") || contains(["fsn1", "nbg1", "hel1"], n.location)
    ])
    error_message = "CAX (ARM64) server types are only available in fsn1, nbg1 and hel1."
  }
}

variable "primary_ip_delete_protection" {
  description = "Protect the nodes' public addresses from deletion. On because they are published and configured into people's devices: with it, `make destroy` or removing a node stops at the addresses instead of releasing them. Set false and `make apply` only to release them on purpose — the shutdown date in docs/TERMS.md."
  type        = bool
  default     = true
}

variable "image" {
  description = "Hetzner image slug. Debian 13 ships unbound 1.22.0 and certbot 4.0.0; PowerDNS publishes dnsdist 2.1 for it."
  type        = string
  default     = "debian-13"
}

# ---------------------------------------------------------------------------
# Access
# ---------------------------------------------------------------------------

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH. This is the only inbound management path."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr must be a valid CIDR, e.g. 203.0.113.4/32."
  }

  validation {
    condition     = !contains(["0.0.0.0/0", "::/0"], var.admin_cidr)
    error_message = "admin_cidr must not be 0.0.0.0/0 or ::/0 — that exposes SSH to the whole internet. Use your own /32 or /128."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key authorised on each node."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# ---------------------------------------------------------------------------
# TLS / ACME (DNS-01 via AWS Route 53)
# ---------------------------------------------------------------------------

variable "acme_email" {
  description = "Contact address for Let's Encrypt expiry notices."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.acme_email))
    error_message = "acme_email must be a valid email address."
  }
}

# NOTE: the AWS credentials are deliberately NOT Terraform variables.
# A sensitive variable is still written to tfstate in plaintext, and anything
# placed in user_data can be read back out of the Hetzner Cloud API for the
# lifetime of the server. `make deploy` reads AWS_ACCESS_KEY_ID and
# AWS_SECRET_ACCESS_KEY from your environment and installs them over SSH as
# /etc/letsencrypt/aws.credentials (0600), so they touch neither state nor
# Hetzner's metadata store.

variable "acme_staging" {
  description = "Use the Let's Encrypt staging CA. Set true while iterating to avoid burning production rate limits; the cert will not be publicly trusted."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Resolution posture
# ---------------------------------------------------------------------------
# This is the single most consequential privacy decision in the whole project,
# so the reasoning lives here rather than only in docs/PRIVACY.md.
#
# Full recursion (forward_tls_upstreams = []) talks to the root, the TLD and the
# domain's own nameservers in CLEARTEXT on port 53. No third-party resolver is
# involved — but the hosting provider, who also sees every client IP arriving on
# 443/853, sees every query name leaving on 53. They hold both halves of the
# identifying pair, and qname-minimisation does not help against them: it limits
# what each nameserver in the chain learns, while a network observer watches the
# whole chain and reassembles the name.
#
# Forwarding over DoT splits those halves across two parties who would have to
# collude. The provider keeps client IPs and sees only ciphertext leaving; the
# upstream sees query names attributed to the node's own address and never sees
# a client. Neither can reconstruct who asked what.
#
# The cost is independence: the upstream's blocking policy applies and this
# resolver's allowlist cannot override it, because an upstream NXDOMAIN never
# reaches the RPZ machinery. See README "Overriding an upstream block".
variable "forward_tls_upstreams" {
  description = <<-EOT
    Upstreams unbound forwards the root zone to, over DNS-over-TLS, as unbound
    forward-addr values: ADDRESS@PORT#TLS-AUTH-NAME.

    The #name is mandatory (enforced below) because without it unbound does
    opportunistic TLS — encrypted but unauthenticated, which a network-position
    adversary can trivially intercept. With it, the upstream certificate must
    match, so the encryption is worth something.

    Defaults to Quad9's FILTERED endpoint, which blocks malware, phishing and C2
    from commercial threat intelligence. That is why no domain-reputation feed
    appears in rpz_blocklists. Alternatives:
      dns10.quad9.net  9.9.9.10 / 149.112.112.10 / 2620:fe::10  — no filtering
      dns11.quad9.net  9.9.9.11 / 149.112.112.11 / 2620:fe::11  — filtering + ECS
    Use dns10 if you would rather own the entire blocking policy yourself; then
    add a malware feed back to rpz_blocklists.

    Set to [] for full recursion from the root. DNSSEC is validated locally
    either way, so the upstream is never trusted to tell the truth — only to
    relay. Both postures are asserted at runtime by `make audit`.
  EOT
  type        = list(string)
  default = [
    "9.9.9.9@853#dns.quad9.net",
    "149.112.112.112@853#dns.quad9.net",
    "2620:fe::fe@853#dns.quad9.net",
    "2620:fe::9@853#dns.quad9.net",
  ]

  validation {
    condition = alltrue([
      for u in var.forward_tls_upstreams :
      can(regex("^[0-9a-fA-F.:]+@[0-9]+#[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", u))
    ])
    error_message = "each forward_tls_upstreams entry must be ADDRESS@PORT#TLS-AUTH-NAME, e.g. 9.9.9.9@853#dns.quad9.net. The #name is required: without it unbound falls back to unauthenticated TLS."
  }

  validation {
    condition = alltrue([
      for u in var.forward_tls_upstreams :
      tonumber(split("#", split("@", u)[1])[0]) == 853
    ])
    error_message = "forward_tls_upstreams must use port 853. Forwarding on 53 would send query names in cleartext, which defeats the entire reason for forwarding."
  }
}

# ---------------------------------------------------------------------------
# Blocklists (RPZ)
# ---------------------------------------------------------------------------

variable "rpz_blocklists" {
  description = <<-EOT
    Ordered list of RPZ blocklist zones. ORDER IS SEMANTIC: unbound applies policy
    zones in the order configured and the first match wins, so this is a list and
    not a map (a map would be iterated in lexicographic key order and would silently
    reorder your policy the day a zone is renamed).

    The local allowlist is always emitted ahead of this list and is not an entry in it.

    min_entries is the floor below which a downloaded zone is rejected as
    truncated or poisoned. Set it well under the real count but far above zero.
  EOT
  type = list(object({
    name        = string
    url         = string
    min_entries = number
  }))

  default = [
    {
      # Ads, trackers, metrics, telemetry. ~456,000 entries as of 2026-09-25.
      name        = "adblock"
      url         = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/pro.txt"
      min_entries = 300000
    },
    {
      # Malware, phishing, scams, C2. ~401,000 entries.
      #
      # This is the MINI feed, not the medium one, and it is deliberately
      # belt-and-braces with the upstream rather than a replacement for it.
      # Measured after the switch to Quad9: of 57 domains sampled from Hagezi TIF
      # medium, Quad9's filtered endpoint blocked 9 and the other 48 resolved
      # through both Quad9 and Google. The two lists are not equivalent, and that
      # measurement cannot say which is right — Quad9 may be more precise, Hagezi
      # may have broader coverage — so running both is the honest answer.
      #
      # Mini rather than medium because medium's 1.75M entries cost ~0.9-1.2 GB
      # and were what forced the caches down to 128m/256m. Mini is a fifth of that.
      #
      # A local block also behaves better than an upstream one: it returns a clean
      # NXDOMAIN, where an upstream block on a DNSSEC-signed zone surfaces as
      # SERVFAIL because our validator rejects the forged denial, and some clients
      # retry SERVFAIL against a fallback resolver. See README.
      name        = "threat"
      url         = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/tif.mini.txt"
      min_entries = 250000
    },
    {
      # Response-IP triggers: blocks resolution TO known-malicious IPs regardless
      # of the domain asked for. Requires `respip` in unbound's module-config.
      #
      # Neither a domain feed nor the upstream can do this: it catches a
      # brand-new or compromised domain pointing at known C2 infrastructure,
      # whatever the domain is. ~34,500 entries / ~1 MB as of 2026-09-27.
      name        = "threatip"
      url         = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/tif-ips.txt"
      min_entries = 20000
    },
  ]

  validation {
    condition     = length(var.rpz_blocklists) == length(distinct([for z in var.rpz_blocklists : z.name]))
    error_message = "rpz_blocklists names must be unique — they become unbound zone names and file names."
  }

  validation {
    condition = alltrue([
      for z in var.rpz_blocklists : can(regex("^[a-z][a-z0-9-]*$", z.name))
    ])
    error_message = "rpz_blocklists names must be lowercase alphanumeric with hyphens (they are used as zone and file names)."
  }

  validation {
    condition = alltrue([
      for z in var.rpz_blocklists : startswith(z.url, "https://")
    ])
    error_message = "rpz_blocklists URLs must be https:// — a plaintext blocklist fetch is trivially tamperable."
  }

  # A floor of 1000 catches the classic failure where a CDN returns a short error
  # body with HTTP 200 and a naive fetcher installs it as the blocklist.
  validation {
    condition = alltrue([
      for z in var.rpz_blocklists : z.min_entries >= 1000
    ])
    error_message = "rpz_blocklists min_entries must be at least 1000 to be a meaningful truncation guard."
  }
}

variable "rpz_update_interval" {
  description = "systemd OnUnitActiveSec interval for blocklist refresh. Hagezi publishes every 4-8h and sets Expires: 8 hours."
  type        = string
  default     = "8h"
}

variable "enable_threat_ip_blocking" {
  description = "Load the response-IP threat zone. Response-IP blocking is the most aggressive layer — one bad shared-CDN IP in the feed takes out every site behind it — so it can be dropped without touching the domain-based zones."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Abuse controls
# ---------------------------------------------------------------------------

# Sizing assumption, decided 2026-09-27: one client address is a household or
# small office of up to 50 devices behind NAT. Not a university, not a CGNAT
# range — those need a different number and a different conversation.
#
# MaxQPSIPRule is a token bucket per address (per /64 for IPv6, which is one LAN):
# it refills at max_qps_per_ip and holds at most max_qps_burst_per_ip. Queries
# arriving with the bucket empty are dropped. It runs before the packet cache, so
# cached answers count too.
#
# What 50 devices actually do:
#   * background — phones, laptops, a smart TV retrying blocked telemetry — sums
#     to a few queries per second at most;
#   * one page load on a heavy site is 30-100 lookups within a second or two, and
#     several people loading pages at once is the peak that matters.
# So the sustained rate is set well above background and the burst covers about
# five heavy page loads landing together. A full bucket refills in 10 seconds.
variable "max_qps_per_ip" {
  description = "Sustained queries per second allowed per client address (IPv6: per /64), enforced inline by dnsdist MaxQPSIPRule. 50 is one per device for a 50-device household, several times a busy household's real average. Queries beyond the rate once the burst is spent are dropped."
  type        = number
  default     = 50

  validation {
    condition     = var.max_qps_per_ip >= 5 && var.max_qps_per_ip <= 10000
    error_message = "max_qps_per_ip must be between 5 and 10000."
  }
}

variable "max_qps_burst_per_ip" {
  description = "Size of each client address's token bucket: how many queries it can send at once before the sustained rate applies. 500 covers several simultaneous heavy page loads from a 50-device household. Before 2026-09-27 this was unset, so dnsdist defaulted it to max_qps_per_ip and a household got no burst headroom at all."
  type        = number
  default     = 500

  validation {
    condition     = var.max_qps_burst_per_ip >= var.max_qps_per_ip
    error_message = "max_qps_burst_per_ip must be at least max_qps_per_ip — the bucket has to hold one second of the sustained rate."
  }
}

# The three dynblock_* settings below only take effect when dynblock_ring_entries
# is above 0, which it is not by default.

variable "dynblock_qps" {
  description = "Sustained queries per second over dynblock_window that cut an address off for dynblock_duration. Only with dynblock_ring_entries > 0. 250 sits five times above max_qps_per_ip, so a 50-device household cannot reach it even with a device stuck in a retry loop — a dynamic block cuts the whole household off, where MaxQPSIPRule only throttles it."
  type        = number
  default     = 250
}

variable "dynblock_window" {
  description = "Seconds of traffic dnsdist evaluates for dynamic blocks. Only with dynblock_ring_entries > 0."
  type        = number
  default     = 10
}

variable "dynblock_duration" {
  description = "Seconds a dynamic block lasts. Only with dynblock_ring_entries > 0."
  type        = number
  default     = 60
}

variable "dynblock_ring_entries" {
  description = <<-EOT
    Capacity of dnsdist's in-RAM query ring — the only place a client address
    and a query name are ever recorded together. 0, the default, means no ring,
    no dynamic blocks, and no such pairing anywhere on the node.

    Off since 2026-09-27, for two measured reasons. The ring holds a COUNT of
    entries, not a span of time: at this resolver's real traffic, 5000 entries
    was about 2 hours of client-and-name history on fsn1-a and days on hel1-a,
    where docs/PRIVACY.md had promised seconds. And of the two rules it fed, the
    NXDOMAIN-flood one never worked — dnsdist evaluates rcode rules on the
    RESPONSE ring, and responses are deliberately not recorded. That left one
    rule, the sustained-rate cut-off, which MaxQPSIPRule's throttle already
    covers for encrypted transports that cannot be used for amplification.

    To turn dynamic blocks back on: set this so it spans dynblock_window seconds
    of TOTAL traffic across all clients (at 500 qps, 5000 covers 10 s) — shorter
    and the rules silently under-count and never fire — and accept that at low
    traffic it retains far longer than the window. Update docs/PRIVACY.md with it.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.dynblock_ring_entries == 0 || var.dynblock_ring_entries >= 100
    error_message = "dynblock_ring_entries must be 0 (rings off) or at least 100."
  }
}

# DNS tunnelling: a covert channel carried in query names and answers, aimed at
# an authoritative server the tunneller runs. An encrypted public resolver is an
# ideal carrier — the local network sees only DoT/DoH — and every tunnelled query
# is a unique name, so all of it goes upstream from THIS node's address, where a
# heavy tunnel can get the node throttled for everyone.
#
# The limits below are per query and record nothing: dnsdist looks at one query,
# decides, and forgets it. That catches the default settings of the common tools
# (iodine, dnscat2), which pack names close to the 255-byte maximum and prefer
# the NULL record type. It does NOT catch a patient tunnel using short names at
# a low rate — spotting that means counting names per domain over time, which is
# exactly the record-keeping this resolver refuses. The per-address rate limit is
# what caps such a tunnel, at roughly 5-10 KB/s. Matches are answered REFUSED,
# never dropped: a drop on DoT closes the client's whole connection, far too harsh
# for a false positive, while REFUSED fails one lookup and is distinguishable from
# a blocklist NXDOMAIN when debugging.

variable "tunnel_max_qname_bytes" {
  description = <<-EOT
    Refuse any query whose name is longer than this on the wire (the protocol
    maximum is 255). 0 disables the rule.

    220 because tunnelling tools fill names to near 255 by default, while the
    longest legitimate names known — antivirus reputation lookups such as McAfee
    GTI and Sophos SXL, which encode file hashes into the name — typically run
    100-180 bytes. That upper figure is from published descriptions of those
    services, not measured here: this resolver records no names, so it cannot
    measure them. `make audit` reports how many queries this rule has matched,
    as a count only, which is the signal to watch for false positives.
  EOT
  type        = number
  default     = 220

  validation {
    condition     = var.tunnel_max_qname_bytes == 0 || (var.tunnel_max_qname_bytes >= 100 && var.tunnel_max_qname_bytes <= 255)
    error_message = "tunnel_max_qname_bytes must be 0 (off) or between 100 and 255. Below 100 refuses ordinary long names — IPv6 reverse lookups alone are 74 bytes."
  }
}

variable "refuse_tunnel_qtypes" {
  description = "Refuse queries for record type NULL (10) and for 65399, the private-use type iodine uses. Nothing ordinary asks for either. TXT is deliberately NOT included: tunnels use it, but so do SPF, DKIM and domain verification."
  type        = bool
  default     = true
}

variable "rate_limit_exempt_cidrs" {
  description = "CIDRs exempt from rate limiting and dynamic blocks. Defaults to admin_cidr so your own testing cannot lock you out. Set to [] for no exemptions."
  type        = list(string)
  default     = null
}

# ---------------------------------------------------------------------------
# Resource sizing
# ---------------------------------------------------------------------------

variable "unbound_msg_cache_size" {
  description = <<-EOT
    unbound msg-cache-size. Doubled from 128m when the 1.75M-entry domain malware
    feed moved upstream: unbound now measures ~557 MB steady with every zone
    loaded, rather than the 0.9-1.2 GB the medium feed alone cost, and cache is
    what stands between a query and an upstream round trip. README "Memory" has the
    measurements, including the ~1.4 GB reload peak the cap must cover.

    Deliberately conservative. Measure actual RSS with `make audit` before going
    higher — there is likely room for 512m/1024m on a 4 GB node, but free RAM is
    not wasted RAM and unbound_memory_max is a cap, not a target.
  EOT
  type        = string
  default     = "256m"
}

variable "unbound_rrset_cache_size" {
  description = "unbound rrset-cache-size. Convention is roughly double msg-cache-size."
  type        = string
  default     = "512m"
}

variable "unbound_memory_max" {
  description = "systemd MemoryMax for unbound. A runaway zone then restarts unbound instead of inviting the OOM killer to pick a victim. Set to empty string to disable the cap."
  type        = string
  default     = "2500M"
}

variable "dnsdist_packet_cache_entries" {
  description = <<-EOT
    Maximum entries in dnsdist's packet cache, which answers repeated questions
    from RAM instead of crossing into unbound. 0 disables it.

    Entries are keyed by question, never by client, so like unbound's own cache it
    can say what was asked recently but never by whom, and nothing reaches disk.
    Budget a few hundred bytes per entry.
  EOT
  type        = number
  default     = 100000

  validation {
    condition     = var.dnsdist_packet_cache_entries >= 0 && var.dnsdist_packet_cache_entries <= 5000000
    error_message = "dnsdist_packet_cache_entries must be between 0 (disabled) and 5,000,000."
  }
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "enable_localhost_metrics" {
  description = <<-EOT
    Bind dnsdist's webserver to 127.0.0.1 for aggregate metrics. Off by default:
    the built-in HTML console can surface topQueries from the in-RAM ring — empty
    while dynblock_ring_entries = 0, but the surface returns if the ring does — so
    this is a privacy-relevant setting even bound to loopback. Reachable only over an
    SSH tunnel when enabled.
  EOT
  type        = bool
  default     = false
}

variable "journal_runtime_max_use" {
  description = "journald RuntimeMaxUse. Logs live in RAM only (Storage=volatile) and are lost on reboot by design."
  type        = string
  default     = "16M"
}
