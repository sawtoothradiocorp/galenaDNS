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
# All nodes share one hostname; multiple values give round-robin spread.
output "dns_records" {
  description = "The resolver's A/AAAA records. Managed by Terraform unless manage_dns_records = false, in which case create these yourself."
  value = var.manage_dns_records ? [
    format("%-32s %-6s %s  (managed by Terraform, TTL %d)", "${var.domain}.", "A",
    join(" ", [for s in hcloud_server.node : s.ipv4_address]), var.dns_record_ttl),
    format("%-32s %-6s %s  (managed by Terraform, TTL %d)", "${var.domain}.", "AAAA",
    join(" ", [for s in hcloud_server.node : s.ipv6_address]), var.dns_record_ttl),
    ] : concat(
    [for k, s in hcloud_server.node : format("%-32s %-6s %s  (CREATE THIS YOURSELF)", "${var.domain}.", "A", s.ipv4_address)],
    [for k, s in hcloud_server.node : format("%-32s %-6s %s  (CREATE THIS YOURSELF)", "${var.domain}.", "AAAA", s.ipv6_address)],
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

output "deploy_hint" {
  description = "What to do next."
  value       = local.deploy_hint
}

output "estimated_monthly_eur" {
  description = "Rough Hetzner list price for the declared nodes, EU pricing, excluding VAT and traffic overage."
  value = format("~EUR %.2f/month for %d node(s)", sum([
    for k, n in var.nodes : lookup({
      cx23  = 5.49
      cx33  = 8.49
      cx43  = 15.99
      cx53  = 29.49
      cax11 = 5.99
      cax21 = 10.49
      cax31 = 20.99
      cax41 = 40.99
      cpx22 = 19.49
      cpx32 = 35.49
      cpx42 = 69.49
      cpx52 = 100.49
    }, n.server_type, 0)
  ]), length(var.nodes))
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
