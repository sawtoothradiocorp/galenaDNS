locals {
  # Zone list handed to the node. The allowlist is not in this list: the unbound
  # template always emits it first, so it cannot be reordered below a blocklist.
  active_blocklists = [
    for z in var.rpz_blocklists : z
    if z.name != "threatip" || var.enable_threat_ip_blocking
  ]

  # null means "default to admin_cidr"; an explicit [] means "no exemptions".
  rate_limit_exempt = var.rate_limit_exempt_cidrs == null ? [var.admin_cidr] : var.rate_limit_exempt_cidrs

  common_labels = {
    project = var.project_name
    managed = "terraform"
  }

  # node.env is sourced by bootstrap.sh to render the config templates.
  # Nothing secret goes in here — it travels through Hetzner's metadata service.
  node_env = {
    GALENA_DOMAIN                  = var.domain
    GALENA_ACME_EMAIL              = var.acme_email
    GALENA_ACME_STAGING            = var.acme_staging ? "1" : "0"
    GALENA_RPZ_ZONES               = join(" ", [for z in local.active_blocklists : z.name])
    GALENA_RPZ_UPDATE_INTERVAL     = var.rpz_update_interval
    GALENA_MAX_QPS_PER_IP          = tostring(var.max_qps_per_ip)
    GALENA_DYNBLOCK_QPS            = tostring(var.dynblock_qps)
    GALENA_DYNBLOCK_WINDOW         = tostring(var.dynblock_window)
    GALENA_DYNBLOCK_DURATION       = tostring(var.dynblock_duration)
    GALENA_DYNBLOCK_RING_ENTRIES   = tostring(var.dynblock_ring_entries)
    GALENA_RATE_LIMIT_EXEMPT       = join(",", local.rate_limit_exempt)
    GALENA_UNBOUND_MSG_CACHE       = var.unbound_msg_cache_size
    GALENA_UNBOUND_RRSET_CACHE     = var.unbound_rrset_cache_size
    GALENA_UNBOUND_MEMORY_MAX      = var.unbound_memory_max
    GALENA_ENABLE_METRICS          = var.enable_localhost_metrics ? "1" : "0"
    GALENA_PACKET_CACHE_ENTRIES    = tostring(var.dnsdist_packet_cache_entries)
    GALENA_JOURNAL_RUNTIME_MAX_USE = var.journal_runtime_max_use
    GALENA_ADMIN_CIDR              = var.admin_cidr
    # Space-separated unbound forward-addr values; empty string means recurse from
    # the root. bootstrap.sh renders the forward-zone block from this, and
    # privacy-audit.sh reads it to know which posture to assert.
    GALENA_FORWARD_UPSTREAMS = join(" ", var.forward_tls_upstreams)
  }

  # Per-zone URL and floor, consumed by rpz-update.sh.
  rpz_manifest = join("\n", [
    for z in local.active_blocklists : "${z.name}\t${z.url}\t${z.min_entries}"
  ])
}

resource "hcloud_ssh_key" "admin" {
  name       = "${var.project_name}-admin"
  public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  labels     = local.common_labels
}

locals {
  # Assembled here rather than inline in the output: HCL cannot follow a closing
  # heredoc with the `:` of a conditional.
  staging_note = var.acme_staging ? join("\n", [
    "",
    "NOTE: acme_staging is on, so the certificate is NOT publicly trusted.",
    "      Pass ARGS=--insecure to `make test` until you set acme_staging = false",
    "      and re-run `make deploy`.",
  ]) : ""

  deploy_hint_managed = <<-EOT
    1. The A/AAAA records were created by Terraform. Confirm they resolve:
         dig +short ${var.domain} A
    2. make deploy
    3. make audit && make test
    ${local.staging_note}
  EOT

  deploy_hint_manual = <<-EOT
    1. Create the records listed in `dns_records` at your DNS provider.
    2. Wait for them to resolve:  dig +short ${var.domain} A
    3. make deploy
    4. make audit && make test
    ${local.staging_note}
  EOT

  deploy_hint = var.manage_dns_records ? local.deploy_hint_managed : local.deploy_hint_manual
}
