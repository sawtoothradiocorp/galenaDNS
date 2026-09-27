# Alerting: the half of failover that tells someone.
#
# Health checks withdraw a dead node from DNS, and that is exactly what hides the
# outage — every client keeps working on the surviving node, nothing anywhere
# says a node died, and the account keeps paying for two. This file is what turns
# the same signals into an email.
#
# One SNS topic, one email subscription, and every alert goes through it:
#
#   * a CloudWatch alarm per Route 53 health check — a node or address family
#     stopped accepting DoT connections;
#   * alerts the external prober (monitor/) publishes itself — certificate
#     expiry, a broken transport, DNSSEC, blocking; everything a TCP check
#     cannot see;
#   * a dead man's switch on the prober: it publishes a heartbeat metric after
#     every run with no failures, and this alarm fires when the heartbeat stops.
#     That covers "the resolver is failing checks" and "the monitor itself is
#     dead" with one signal, and it is evaluated by AWS, so it does not depend on
#     the monitor host being alive to report its own death.
#
# Cost: nothing, as deployed. CloudWatch's always-free tier is 10 alarms and 10
# custom metrics per account and this uses 5 and 1 — the account had none of
# either on 2026-09-27. SNS email is free for the first 1,000 notifications a
# month. outputs.tf prices it if the free tier is ever exceeded.
#
# The prober's AWS key is deliberately NOT created here: an aws_iam_access_key
# writes its secret to tfstate. Terraform creates the user and its policy;
# `make monitor-key` mints the key and ships it straight to the monitor host,
# the same way `make deploy` handles the ACME key.

locals {
  monitoring_enabled = var.manage_dns_records && var.alert_email != ""

  # Must match monitor/galena-probe. The IAM policy below scopes PutMetricData to
  # this namespace, so the prober's key can write nothing else.
  heartbeat_namespace = var.project_name
  heartbeat_metric    = "ProbeSuccess"

  # Keys come from var.nodes so they are known at plan time; the IDs are not, and
  # need not be.
  alarmed_health_checks = !local.monitoring_enabled ? {} : merge(
    local.failover_enabled ? { for k in keys(var.nodes) : "${k}-v4" => aws_route53_health_check.node_v4[k].id } : {},
    local.failover_enabled && var.dns_health_check_ipv6 ? { for k in keys(var.nodes) : "${k}-v6" => aws_route53_health_check.node_v6[k].id } : {},
  )

  cloudwatch_alarm_count  = length(local.alarmed_health_checks) + (local.monitoring_enabled ? 1 : 0)
  cloudwatch_metric_count = local.monitoring_enabled ? 1 : 0
}

resource "aws_sns_topic" "alerts" {
  count = local.monitoring_enabled ? 1 : 0

  name = "${var.project_name}-alerts"
  tags = local.common_labels
}

# Email subscriptions start as "PendingConfirmation": AWS mails a link to
# var.alert_email and nothing is delivered until someone clicks it. Terraform
# cannot confirm it and cannot delete it while it is pending (it expires on its
# own after three days), so a typo here is fixed by correcting the address and
# applying again, not by destroying.
resource "aws_sns_topic_subscription" "alert_email" {
  count = local.monitoring_enabled ? 1 : 0

  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# One alarm per health check, so the email names the node and address family.
#
# The metric is 1 while Route 53 considers the endpoint healthy. It already
# takes ~90 seconds of failures to flip, so three one-minute datapoints on top
# keeps a single blip from paging while still reporting within ~5 minutes.
#
# treat_missing_data = breaching: Route 53 publishes this every minute for as
# long as the check exists, so silence means the check was disabled or deleted
# out from under us — which is itself worth an email.
resource "aws_cloudwatch_metric_alarm" "node_health" {
  for_each = local.alarmed_health_checks

  alarm_name        = "${var.project_name}-${each.key}-dot-down"
  alarm_description = "Route 53 health check for ${each.key}: TCP/${var.dns_health_check_port} is failing, so this address has been withdrawn from ${var.domain}. Clients are on the remaining nodes. See README \"Failover\"."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  dimensions  = { HealthCheckId = each.value }
  statistic   = "Minimum"
  period      = 60

  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]

  tags = local.common_labels
}

# The dead man's switch. The prober runs every 5 minutes and publishes
# ProbeSuccess = 1 after any run with no FAIL; this fires after 20 minutes with
# no such datapoint. Four empty five-minute periods rather than one, because
# systemd timer drift can leave a single period empty on a healthy monitor.
#
# Until the prober is installed there is no datapoint at all, so this goes into
# ALARM about 20 minutes after it is created. That is correct — the monitor is
# not running — and it clears on its own once the first heartbeat lands.
resource "aws_cloudwatch_metric_alarm" "probe_heartbeat" {
  count = local.monitoring_enabled ? 1 : 0

  alarm_name        = "${var.project_name}-probe-silent"
  alarm_description = "No passing run from the external prober on ${var.monitor_host} for 20 minutes. Either the resolver is failing its checks (the prober's own alert has the detail), or the prober, its timer or its host has stopped."

  namespace   = local.heartbeat_namespace
  metric_name = local.heartbeat_metric
  statistic   = "Sum"
  period      = 300

  evaluation_periods  = 4
  datapoints_to_alarm = 4
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.alerts[0].arn]
  ok_actions    = [aws_sns_topic.alerts[0].arn]

  tags = local.common_labels
}

# The prober's identity: publish to this one topic, write this one namespace.
# Nothing else — in particular no Route 53, so a key stolen off the monitor host
# can neither repoint the resolver nor read the zone.
resource "aws_iam_user" "probe" {
  count = local.monitoring_enabled ? 1 : 0

  name = "${var.project_name}-probe"
  tags = local.common_labels
}

resource "aws_iam_user_policy" "probe" {
  count = local.monitoring_enabled ? 1 : 0

  name = "${var.project_name}-probe-publish-only"
  user = aws_iam_user.probe[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts[0].arn
      },
      {
        # PutMetricData has no resource-level permissions; the namespace
        # condition is the only way to scope it.
        Effect    = "Allow"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = local.heartbeat_namespace } }
      },
    ]
  })
}
