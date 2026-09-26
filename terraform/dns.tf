# Route 53 records for the resolver hostname.
#
# All nodes share one hostname; one A (and one AAAA) record with several values
# gives round-robin spread across them. Records are not secret, so unlike the
# ACME credentials there is no reason to keep these out of Terraform.
#
# ACME DNS-01 does not depend on these existing — it only needs the
# _acme-challenge TXT record, which certbot creates and removes itself. These are
# purely so clients can find the resolver.

locals {
  domain_labels = split(".", var.domain)

  # Derive the hosted zone from the domain when not given: the last two labels.
  # That is wrong for multi-part public suffixes (example.co.uk), which is why
  # route53_zone_name exists as an override.
  zone_name = var.route53_zone_name != "" ? var.route53_zone_name : join(
    ".", slice(local.domain_labels, length(local.domain_labels) - 2, length(local.domain_labels))
  )
}

data "aws_route53_zone" "this" {
  count        = var.manage_dns_records ? 1 : 0
  name         = local.zone_name
  private_zone = false
}

resource "aws_route53_record" "a" {
  count = var.manage_dns_records ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = var.dns_record_ttl
  records = [for s in hcloud_server.node : s.ipv4_address]

  # Fail rather than clobber a record that already exists and is not in state.
  # A resolver hostname silently taking over an existing record would be worse
  # than a loud error here.
  allow_overwrite = false
}

resource "aws_route53_record" "aaaa" {
  count = var.manage_dns_records ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "AAAA"
  ttl     = var.dns_record_ttl
  records = [for s in hcloud_server.node : s.ipv6_address]

  allow_overwrite = false
}
