# Route 53 records for the resolver hostname, the health checks that make a dead
# node disappear from them, and the CAA record that says who may certify it.
#
# All nodes share one hostname. Each node contributes its own A (and AAAA) record
# set under a `multivalue_answer_routing_policy`, which is what makes failover
# possible: Route 53 returns up to 8 of the HEALTHY values, in random order, so
# clients still spread across nodes but stop being handed an address that is down.
#
# A plain multi-value record set cannot do this. Route 53 will only consult a
# health check for a record that carries a set identifier, so "one record set with
# two values" and "health-checked failover" are mutually exclusive shapes. That is
# why each node gets its own record rather than another entry in a list.
#
# Records are not secret, so unlike the ACME credentials there is no reason to keep
# these out of Terraform.
#
# ACME DNS-01 does not depend on the records or the health checks — it only needs
# the _acme-challenge TXT record, which certbot creates and removes itself. It
# does depend on the CAA record at the bottom of this file, which is the one thing
# here that can stop a certificate being issued at all.

locals {
  domain_labels = split(".", var.domain)

  # Derive the hosted zone from the domain when not given: the last two labels.
  # That is wrong for multi-part public suffixes (example.co.uk), which is why
  # route53_zone_name exists as an override.
  zone_name = var.route53_zone_name != "" ? var.route53_zone_name : join(
    ".", slice(local.domain_labels, length(local.domain_labels) - 2, length(local.domain_labels))
  )

  # Three conditions, each one load-bearing:
  #
  #   manage_dns_records — a health check is only useful when something consults
  #     it, and the only thing that can is a record Terraform owns.
  #   enable_dns_failover — the off switch, because these are billable.
  #   length(var.nodes) > 1 — with one node there is nowhere to fail over TO.
  #     Route 53 returns every value when ALL of them are unhealthy (so that a
  #     total outage degrades to "still answers" rather than NXDOMAIN), which
  #     means a single health-checked node behaves exactly like an unchecked one.
  #     Paying for that would buy nothing, so it is not created.
  failover_enabled = var.manage_dns_records && var.enable_dns_failover && length(var.nodes) > 1

  # Why the IPv6 address gets its own check rather than borrowing the IPv4 one:
  # the families fail independently. A dnsdist that binds 0.0.0.0:853 but fails on
  # [::]:853, an nftables ip6 rule that is wrong, or Hetzner losing a /64's route
  # all leave IPv4 perfectly healthy. A v6-only client — an Android phone on a
  # mobile network — would then be pinned to a node that cannot answer it, and a
  # v4 health check would report everything fine. The cost is one extra check per
  # node; set dns_health_check_ipv6 = false to halve the health-check bill and
  # accept that blind spot.
  health_check_count = local.failover_enabled ? length(var.nodes) * (var.dns_health_check_ipv6 ? 2 : 1) : 0
}

data "aws_route53_zone" "this" {
  # Either knob needs the zone id, and they are independent: the issuance policy
  # is worth publishing even where the A/AAAA records are maintained by hand.
  count        = var.manage_dns_records || var.manage_caa_record ? 1 : 0
  name         = local.zone_name
  private_zone = false
}

# ---------------------------------------------------------------------------
# Health checks
# ---------------------------------------------------------------------------
# TCP on 853 (DoT), from 16 Route 53 checkers — two in each of 8 AWS regions,
# measured 2026-09-27. Each checker calls the endpoint failed after
# failure_threshold consecutive failures, and Route 53 treats the endpoint as
# healthy only while MORE than 18% of checkers report it healthy. 18% of 16 is
# 2.88, so it stays healthy while 3 or more checkers pass and goes unhealthy when
# 14 of the 16 report it down.
#
# What this proves: the node is reachable and something is accepting connections
# on the DoT port. That covers the failures that actually take a node out — the
# VM gone, the host network gone, dnsdist dead or not listening.
#
# What it does NOT prove, and it is worth being precise rather than reassured:
#   * that the certificate is valid. Route 53 completes a TCP handshake, not a
#     TLS one. An expired certificate leaves every check green while every client
#     fails, and expiry hits both nodes at once so failover could not help anyway.
#   * that unbound is alive. dnsdist keeps listening with a dead backend and
#     answers SERVFAIL, which reads as healthy here.
#   * that DoH, DoH3 or DoQ work. Those are separate listeners on separate ports
#     and protocols; only 853/tcp is probed.
#
# Route 53 has no DoT- or DNS-aware check type, so closing those gaps means an
# external prober that speaks DNS — docs/BACKLOG.md section 1. This is the cheap half
# that removes a dead address automatically; that is the half that watches for the
# quiet failures.
#
# No firewall change is needed: both the Hetzner Cloud Firewall and the host
# nftables ruleset already accept tcp/853 from 0.0.0.0/0 and ::/0, and neither
# rate-limits new connections on it.

resource "aws_route53_health_check" "node_v4" {
  for_each = local.failover_enabled ? var.nodes : {}

  type              = "TCP"
  ip_address        = hcloud_server.node[each.key].ipv4_address
  port              = var.dns_health_check_port
  request_interval  = var.dns_health_check_interval
  failure_threshold = var.dns_health_check_failure_threshold

  # Billable optional feature ($2.00/month/check on a non-AWS endpoint) and it
  # only populates a CloudWatch metric nothing here reads. Explicit rather than
  # left to the default, so enabling it is a visible decision.
  measure_latency = false

  tags = merge(local.common_labels, {
    Name = "${var.project_name}-${each.key}-v4-dot"
    node = each.key
  })

  lifecycle {
    # request_interval and measure_latency cannot be changed in place — Route 53
    # replaces the check, which means a new ID, which means Terraform must update
    # the record that points at it. Harmless, but it explains the churn in a plan
    # that only changed the interval.
    create_before_destroy = true
  }
}

resource "aws_route53_health_check" "node_v6" {
  for_each = local.failover_enabled && var.dns_health_check_ipv6 ? var.nodes : {}

  type = "TCP"
  # ::1 of the node's /64, matching what rdns.tf and the AAAA record use.
  ip_address        = hcloud_server.node[each.key].ipv6_address
  port              = var.dns_health_check_port
  request_interval  = var.dns_health_check_interval
  failure_threshold = var.dns_health_check_failure_threshold

  measure_latency = false

  tags = merge(local.common_labels, {
    Name = "${var.project_name}-${each.key}-v6-dot"
    node = each.key
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

resource "aws_route53_record" "a" {
  for_each = var.manage_dns_records ? var.nodes : {}

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "A"
  ttl     = var.dns_record_ttl
  records = [hcloud_server.node[each.key].ipv4_address]

  # The node key. Route 53 requires it to distinguish record sets that share a
  # name and type, and it is what identifies the node in the console.
  set_identifier                   = each.key
  multivalue_answer_routing_policy = true

  # null, not omitted-when-disabled: an unchecked multivalue record is always
  # returned, which is the pre-failover behaviour.
  health_check_id = local.failover_enabled ? aws_route53_health_check.node_v4[each.key].id : null

  # Fail rather than clobber a record that already exists and is not in state.
  # A resolver hostname silently taking over an existing record would be worse
  # than a loud error here.
  allow_overwrite = false
}

resource "aws_route53_record" "aaaa" {
  for_each = var.manage_dns_records ? var.nodes : {}

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "AAAA"
  ttl     = var.dns_record_ttl
  records = [hcloud_server.node[each.key].ipv6_address]

  set_identifier                   = each.key
  multivalue_answer_routing_policy = true

  # Falls back to the IPv4 check when v6 checking is off: "the node is up" is a
  # better answer for the AAAA record than no check at all.
  health_check_id = !local.failover_enabled ? null : (
    var.dns_health_check_ipv6
    ? aws_route53_health_check.node_v6[each.key].id
    : aws_route53_health_check.node_v4[each.key].id
  )

  allow_overwrite = false
}

# ---------------------------------------------------------------------------
# CAA: which CA may certify this name, and how it has to prove itself
# ---------------------------------------------------------------------------
# A CAA record is an allowlist of certificate authorities, published in the zone
# the name lives in. Every publicly trusted CA is required by the CA/Browser
# Forum Baseline Requirements to read it within 8 hours of issuing and to refuse
# if it is not listed. With no CAA record anywhere above the name — which is how
# this zone stood until this record landed — ANY publicly trusted CA will issue
# for var.domain to whoever passes its own validation, and the first sign of it
# is a Certificate Transparency entry nobody is watching.
#
# That matters more here than for a web host. dnsdist authenticates itself to
# every client with this one certificate and nothing else: a DoT client pinned to
# var.domain trusts any publicly trusted certificate for that name, so a
# mis-issuance by a CA this project has never used is a working interception of
# every query on the link that exists to stop exactly that. This record is the
# cheap half of preventing it. CT monitoring is the other half and is not done —
# see docs/BACKLOG.md.
#
# VALIDATION IS A TREE WALK AND THE CLOSEST RECORD WINS. A CA asked to issue for
# base.dns.swthrc.com checks base.dns.swthrc.com, then swthrc.com, then com, and
# uses the FIRST name that has a CAA record. It does not merge them. So this
# record REPLACES whatever the apex publishes rather than adding to it, and the
# apex stays deliberately permissive — it carries an ACM-issued certificate for a
# CloudFront redirect, which a Let's Encrypt-only policy would break at renewal.
# The two are different policies for different names on purpose; do not
# "reconcile" them.
#
#   issue "letsencrypt.org;validationmethods=dns-01"
#     Let's Encrypt, and only by DNS-01 — the method node/bootstrap.sh actually
#     uses (certbot certonly --dns-route53). Naming the method is what makes this
#     more than a CA allowlist. HTTP-01 and TLS-ALPN-01 are proved by answering
#     on a port, so anyone who can get between a CA's validator and this node's
#     :80 or :853 could satisfy them; DNS-01 can only be proved by writing a TXT
#     record in a hosted zone, which is a different and much smaller set of
#     people. Identifier and parameter are RFC 8657, spelled the way Let's
#     Encrypt's own documentation spells them, with no space after the semicolon.
#
#     The staging CA is covered by the same entry, which is why acme_staging =
#     true still works: Let's Encrypt publishes ONE CAA identity,
#     letsencrypt.org, for staging and production both. There is no way to allow
#     one and not the other by CA name.
#
#   issuewild ";"
#     No wildcards, from anyone. bootstrap.sh asks for exactly one name
#     (-d "$GALENA_DOMAIN"), so nothing here needs *.base.dns.swthrc.com, and
#     without this line the issue entry above would permit it — issue governs
#     wildcard issuance too until an issuewild record appears. An empty value is
#     RFC 8659's spelling of "no issuer is authorised". issuewild, once present,
#     governs wildcards exclusively, so it deliberately repeats nothing from the
#     entry above.
#
# accounturi is ABSENT, as a judgement rather than an oversight: the value is per
# node and per environment, and a node rebuild invents a new one. The reasoning
# and what it would take are in docs/BACKLOG.md section 4.
#
# WHAT THIS DOES NOT DO. It constrains honest CAs. A compromised one can ignore
# CAA, browsers never read it, and it has no effect on certificates that already
# exist. It is also only as trustworthy as the zone publishing it, which is the
# real reason the node's ACME key is scoped to TXT and nothing else (README,
# credential 2): a key that could write CAA would rewrite this record first and
# then issue whatever it liked.
#
# If this record is ever wrong the symptom is certbot refusing with "CAA record
# for <name> prevents issuance" — see README "Troubleshooting".
resource "aws_route53_record" "caa" {
  count = var.manage_caa_record ? 1 : 0

  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "CAA"

  # Not var.dns_record_ttl: that is short to keep failover fast, which is not a
  # concern a record read once per issuance shares. Five minutes is still short
  # enough that a mistake here can be corrected and the issuance retried
  # immediately, and that is the only latency this record has.
  ttl = 300

  records = [
    "0 issue \"letsencrypt.org;validationmethods=dns-01\"",
    "0 issuewild \";\"",
  ]

  # Same reasoning as the A/AAAA records above, with more at stake: a CAA record
  # already in the zone and not in state is somebody's issuance policy, and
  # quietly replacing it could break a renewal that has nothing to do with this
  # project. Fail and let a human read it first.
  allow_overwrite = false
}
