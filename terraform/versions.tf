terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.66.0 is current as of 2026-09-21. Only used for Route 53 — the A/AAAA
      # records and their health checks; required even when manage_dns_records =
      # false, but then unused.
      version = "~> 6.66"
    }
    hcloud = {
      source = "hetznercloud/hcloud"
      # 1.69.0 is current as of 2026-09-11. Pinned to the minor series so
      # `terraform init -upgrade` picks up fixes but not breaking changes.
      version = "~> 1.69"
    }
  }
}

provider "hcloud" {
  # Token comes from the HCLOUD_TOKEN environment variable only.
  # Never set it here and never put it in a .tfvars file.
}

provider "aws" {
  # Credentials come from the environment — never from this file or a .tfvars.
  # On a machine with AWS SSO configured, the cleanest path is:
  #     aws sso login --profile <name>
  #     export AWS_PROFILE=<name>
  # which avoids a long-lived access key entirely. AWS_ACCESS_KEY_ID /
  # AWS_SECRET_ACCESS_KEY work too, but when var.aws_profile is set below it wins
  # over them — so the TXT-only ACME key exported for `make deploy` is ignored
  # here. Verified with 6.66 on 2026-09-27. That key could not run a plan anyway:
  # it is denied the health-check reads.
  #
  # Route 53 is global, but the provider still requires a region.
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  # The AWS provider resolves credentials when it is CONFIGURED, not when it is
  # first used, and Terraform configures it whenever dns.tf declares resources —
  # even with count = 0. Without the placeholders below, `manage_dns_records =
  # false` would still demand working AWS credentials for a plan that touches no
  # AWS resource at all, and would fail on an expired SSO cache.
  #
  # When records ARE managed these are null, so the normal credential chain
  # (AWS_PROFILE, env vars, SSO) applies as usual.
  access_key = var.manage_dns_records ? null : "unused-placeholder"
  secret_key = var.manage_dns_records ? null : "unused-placeholder"

  # Skip the eager STS pre-flight. Real API calls still fail loudly on bad
  # credentials; this only stops the provider probing at configure time.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
}
