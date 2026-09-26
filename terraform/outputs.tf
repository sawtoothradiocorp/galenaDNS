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
# All nodes share one hostname; multiple A/AAAA records give round-robin spread.
output "dns_records" {
  description = "Create exactly these records at your DNS provider before running `make deploy`."
  value = concat(
    [for k, s in hcloud_server.node : format("%-28s %-6s %s", "${var.domain}.", "A", s.ipv4_address)],
    [for k, s in hcloud_server.node : format("%-28s %-6s %s", "${var.domain}.", "AAAA", s.ipv6_address)],
  )
}

output "deploy_hint" {
  description = "What to do next."
  value       = <<-EOT
    1. Create the records listed in `dns_records` at your DNS provider.
    2. Wait for them to resolve:  dig +short ${var.domain} A
    3. export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   (Route 53 DNS-01)
    4. make deploy
    5. make audit && make test
  EOT
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
