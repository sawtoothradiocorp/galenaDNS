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
  description = "Create the A/AAAA records for var.domain in Route 53. When true, plan and apply need AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment. Set false to manage the records yourself."
  type        = bool
  default     = true
}

variable "route53_zone_name" {
  description = "Hosted zone holding var.domain, e.g. swthrc.com. Leave empty to derive it as the last two labels of var.domain; set it explicitly for multi-part public suffixes such as example.co.uk."
  type        = string
  default     = ""
}

variable "dns_record_ttl" {
  description = "TTL for the resolver's A/AAAA records. Kept short so a node can be replaced without clients caching a dead address for long."
  type        = number
  default     = 300

  validation {
    condition     = var.dns_record_ttl >= 60 && var.dns_record_ttl <= 86400
    error_message = "dns_record_ttl must be between 60 and 86400 seconds."
  }
}

variable "aws_region" {
  description = "Region for the AWS provider. Route 53 is global, but the provider requires one."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS profile for Terraform to use, e.g. an SSO profile. Leave empty to use AWS_PROFILE or the standard credential chain. Terraform only needs Route 53 access; it is separate from the long-lived key the node uses for ACME renewal."
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
      # Malware, phishing, scams, command-and-control. ~1,747,000 entries.
      # Swap to rpz/tif.mini.txt (~401,000) if this proves too noisy or too large.
      name        = "threat"
      url         = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/rpz/tif.medium.txt"
      min_entries = 1000000
    },
    {
      # Response-IP triggers: blocks resolution TO known-malicious IPs regardless
      # of the domain asked for. Requires `respip` in unbound's module-config.
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
  description = "systemd OnCalendar/OnUnitActiveSec interval for blocklist refresh. Hagezi publishes every 4-8h and sets Expires: 8 hours."
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

variable "max_qps_per_ip" {
  description = "Per-client-IP query rate ceiling enforced inline by dnsdist MaxQPSIPRule. Queries above this are dropped. Keep generous: a NATed office or a CGNAT range shares one IP."
  type        = number
  default     = 40

  validation {
    condition     = var.max_qps_per_ip >= 5 && var.max_qps_per_ip <= 10000
    error_message = "max_qps_per_ip must be between 5 and 10000."
  }
}

variable "dynblock_qps" {
  description = "Sustained QPS over dynblock_window that triggers a dynamic block."
  type        = number
  default     = 100
}

variable "dynblock_window" {
  description = "Seconds of traffic dnsdist evaluates for dynamic blocks. Also the depth of the in-RAM ring window described in PRIVACY.md."
  type        = number
  default     = 10
}

variable "dynblock_duration" {
  description = "Seconds a dynamic block lasts."
  type        = number
  default     = 60
}

variable "dynblock_ring_entries" {
  description = <<-EOT
    Capacity of dnsdist's in-RAM query ring, in queries. This is the single
    number that sets how much client data exists anywhere in the system, so it is
    a variable rather than a constant.

    It must span dynblock_window seconds of TOTAL traffic across all clients, not
    just the abusive one: if the ring is shorter than the window, dynamic blocks
    silently under-count and stop firing. 5000 entries covers ~500 qps over a
    10s window. Set to 0 to disable the rings entirely, which also disables
    dynamic blocks and leaves only MaxQPSIPRule.
  EOT
  type        = number
  default     = 5000

  validation {
    condition     = var.dynblock_ring_entries == 0 || var.dynblock_ring_entries >= 100
    error_message = "dynblock_ring_entries must be 0 (rings off) or at least 100."
  }
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
  description = "unbound msg-cache-size. Sized deliberately because ~2.26M RPZ entries already claim roughly 0.9-1.2 GB."
  type        = string
  default     = "128m"
}

variable "unbound_rrset_cache_size" {
  description = "unbound rrset-cache-size. Convention is roughly double msg-cache-size."
  type        = string
  default     = "256m"
}

variable "unbound_memory_max" {
  description = "systemd MemoryMax for unbound. A runaway zone then restarts unbound instead of inviting the OOM killer to pick a victim. Set to empty string to disable the cap."
  type        = string
  default     = "2500M"
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

variable "enable_localhost_metrics" {
  description = <<-EOT
    Bind dnsdist's webserver to 127.0.0.1 for aggregate metrics. Off by default:
    the built-in HTML console can surface topQueries from the in-RAM ring, so this
    is a privacy-relevant surface even bound to loopback. Reachable only over an
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
