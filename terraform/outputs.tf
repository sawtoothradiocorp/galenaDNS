output "nodes" {
  description = "Per-node addresses."
  value = {
    for k, s in hcloud_server.node : k => {
      ipv4        = s.ipv4_address
      ipv6        = s.ipv6_address
      location    = s.location
      server_type = s.server_type
    }
  }
}

output "ssh" {
  description = "Ready-to-paste SSH commands."
  value       = { for k, s in hcloud_server.node : k => "ssh root@${s.ipv4_address}" }
}

# Printed rather than documented so the README can never drift from reality.
# All nodes share one hostname. Each node has its OWN record set, distinguished by
# a set identifier, under a multivalue-answer routing policy — Route 53 returns up
# to 8 of the healthy ones in random order. "hc" marks a record with a health check
# attached, which is the difference between distribution and failover.
output "dns_records" {
  description = "The resolver's A/AAAA record sets, one per node. Managed by Terraform unless manage_dns_records = false, in which case create these yourself."
  value = var.manage_dns_records ? concat(
    [for k, r in aws_route53_record.a : format("%-32s %-6s %-40s set=%-8s TTL %d  %s",
      "${var.domain}.", "A", one(r.records), r.set_identifier, r.ttl,
    r.health_check_id != "" ? "hc" : "no health check")],
    [for k, r in aws_route53_record.aaaa : format("%-32s %-6s %-40s set=%-8s TTL %d  %s",
      "${var.domain}.", "AAAA", one(r.records), r.set_identifier, r.ttl,
    r.health_check_id != "" ? "hc" : "no health check")],
    ) : concat(
    [for k, s in hcloud_server.node : format("%-32s %-6s %s  (CREATE THIS YOURSELF)", "${var.domain}.", "A", s.ipv4_address)],
    [for k, s in hcloud_server.node : format("%-32s %-6s %s  (CREATE THIS YOURSELF)", "${var.domain}.", "AAAA", s.ipv6_address)],
  )
}

# Says out loud whether a dead node actually disappears from DNS, and how long that
# takes, because "there are two nodes" and "there is failover" are different claims
# and only one of them is worth relying on.
output "dns_failover" {
  description = "Whether Route 53 health checks are withdrawing dead nodes, and the worst-case time for a client to stop being handed a dead address."
  value = local.failover_enabled ? format(
    "on — %d health check(s), TCP/%d every %ds, %d failures to fail. Worst case for a client to move off a dead node: ~%ds (%ds detection + %ds record TTL).",
    local.health_check_count,
    var.dns_health_check_port,
    var.dns_health_check_interval,
    var.dns_health_check_failure_threshold,
    var.dns_health_check_interval * var.dns_health_check_failure_threshold + var.dns_record_ttl,
    var.dns_health_check_interval * var.dns_health_check_failure_threshold,
    var.dns_record_ttl,
    ) : (
    !var.manage_dns_records ? "off — manage_dns_records = false, so Terraform owns no record to attach a check to" :
    length(var.nodes) < 2 ? "off — one node, so there is nowhere to fail over to. A health check here would cost money and change nothing: Route 53 returns every value when all of them are unhealthy." :
    "off — enable_dns_failover = false. Both addresses are always returned, so a client pinned to a dead node stays broken until it retries."
  )
}

# PTRs are set at Hetzner, not in Route 53, so they will not show up in the
# hosted zone. Printed here so `make nodes` output and reality can be compared.
output "rdns_records" {
  description = "Reverse DNS set on each node's public addresses."
  value = concat(
    [for k, r in hcloud_rdns.ipv4 : format("%-40s PTR    %s", "${r.ip_address}.", r.dns_ptr)],
    [for k, r in hcloud_rdns.ipv6 : format("%-40s PTR    %s", "${r.ip_address}.", r.dns_ptr)],
  )
}

output "route53_zone" {
  description = "Hosted zone the records were placed in."
  value       = var.manage_dns_records ? "${local.zone_name} (${data.aws_route53_zone.this[0].zone_id})" : "not managed"
}

# The IDs are needed to ask Route 53 what it currently thinks, which no Terraform
# output can tell you — state holds the configuration, not the live verdict:
#   aws route53 get-health-check-status --health-check-id <id>
output "dns_health_checks" {
  description = "Route 53 health check IDs per node and address family. Empty when failover is off."
  value = merge(
    { for k, h in aws_route53_health_check.node_v4 : "${k}-v4" => h.id },
    { for k, h in aws_route53_health_check.node_v6 : "${k}-v6" => h.id },
  )
}

output "deploy_hint" {
  description = "What to do next."
  value       = local.deploy_hint
}

# Prices verified against the account's own /v1/pricing endpoint on 2026-09-27.
# Two things this got wrong before and which are easy to get wrong again: the
# account is billed in USD, not EUR, and a primary IPv4 is charged separately at
# $0.60/node/month on top of the server price. The figure below is what `make
# apply` shows you before you spend anything, so understating it defeats the
# point of printing it. Re-check with:
#   curl -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/pricing
#
# US locations (ash, hil) are a different and much more expensive product line —
# the cheapest 4 GB type there is cpx21 at $37.49 against cx23's $6.49 in the EU.
# None of the cx* types are offered there at all, so a US node is not a one-line
# change to var.nodes; see README "Costs".
#
# Route 53 health checks are the other recurring charge, and they are billed at the
# NON-AWS endpoint rate because the endpoints are Hetzner addresses: $0.75 per check
# per month, against $0.50 for an AWS endpoint (and the 50 free checks apply only to
# AWS endpoints, so none of these are free). A 10-second interval is billed as an
# "optional feature" at a further $2.00 per check. Prices from
# https://aws.amazon.com/route53/pricing/ on 2026-09-27; unlike Hetzner's, they are
# list prices rather than this account's own, since the Pricing API is not read here.
#
# Query charges are omitted: multivalue-answer is billed as a standard query at
# $0.40/million, and at TTL 60 a handful of clients generate thousands of queries a
# month, not millions. It rounds to zero and pretending to price it would be noise.
locals {
  health_check_unit_monthly = 0.75 + (var.dns_health_check_interval == 10 ? 2.00 : 0)
  health_check_monthly      = local.health_check_count * local.health_check_unit_monthly

  hetzner_monthly = sum([
    for k, n in var.nodes : 0.60 + lookup({
      cx23  = 6.49
      cx33  = 9.99
      cx43  = 19.99
      cx53  = 37.99
      cax11 = 6.99
      cax21 = 12.49
      cax31 = 24.99
      cax41 = 49.99
      cpx21 = 37.49
      cpx22 = 22.99
      cpx31 = 73.49
      cpx32 = 41.99
      ccx13 = 50.99
    }, n.server_type, 0)
  ])
}

output "estimated_monthly_cost" {
  description = "List price for everything recurring: Hetzner nodes with their primary IPv4, plus Route 53 health checks. USD, excluding traffic overage."
  value = format(
    "~USD %.2f/month — %.2f Hetzner (%d node(s), incl. $0.60/node primary IPv4)%s",
    local.hetzner_monthly + local.health_check_monthly,
    local.hetzner_monthly,
    length(var.nodes),
    local.health_check_count > 0
    ? format(" + %.2f Route 53 (%d health check(s) at $%.2f)", local.health_check_monthly, local.health_check_count, local.health_check_unit_monthly)
    : " + 0.00 Route 53 (no health checks)",
  )
}

output "domain" {
  description = "The configured public hostname. Used by the Makefile for test and destroy confirmation."
  value       = var.domain
}

output "rpz_feed_urls" {
  description = "Active blocklist feed URLs. `make test` samples malware fixtures from these so the test tracks the deployed config instead of hardcoded domains."
  value       = [for z in local.active_blocklists : z.url]
}

# These two are what bootstrap.sh reads. They are outputs, not just cloud-init
# content, because cloud-init only runs on FIRST boot: without them here, editing
# any galena setting in tfvars could never reach an already-running node.
# `make deploy` pushes them on every run, so they are the live source of truth.
output "node_env" {
  description = "Rendered node.env contents (no secrets)."
  value       = join("\n", [for k in sort(keys(local.node_env)) : "${k}=\"${local.node_env[k]}\""])
}

output "rpz_manifest" {
  description = "Tab-separated blocklist manifest: name, url, min_entries."
  value       = local.rpz_manifest
}
