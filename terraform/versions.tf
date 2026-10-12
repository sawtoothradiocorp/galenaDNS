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

  # State is GitLab-managed, not a file on one machine.
  #
  # Until 2026-10-11 the backend was local, so the only record of 18 live
  # resources sat in one working copy on one machine, with
  # terraform.tfstate.backup exactly one apply behind it and no locking of any
  # kind. More than one admin host does this work now, and two of them holding
  # divergent local state is how a node gets adopted twice or orphaned.
  #
  # This shares STATE ONLY. It is not a step toward running Terraform in CI, and
  # should not be read as one: this repository is public, so a runner holding
  # HCLOUD_TOKEN would execute whatever an MR author put in a provisioner or an
  # `external` data source, on a branch nobody has read yet. Applies stay on
  # trusted hosts, by hand.
  #
  # Publishing the repository does not publish the state. The endpoint below is
  # authenticated API only; an unauthenticated GET gets 404, not the state.
  #
  # Auth is HTTP Basic, from the environment, never from this file:
  #     export TF_HTTP_USERNAME=<gitlab username>
  #     export TF_HTTP_PASSWORD=<personal access token, api scope>
  # Verified 2026-10-11: an `api`-scoped PAT is required. The token `glab` keeps
  # in the system keyring is an OAuth token — it authenticates as
  # `Authorization: Bearer` but is refused 401 under Basic auth, which is what
  # this backend sends, so it cannot be reused here.
  #
  # 86968566 is this project's numeric id. `galena-dns` is the state name within
  # the project: changing it silently points Terraform at a different and empty
  # state, so it does not change once state is stored under it.
  backend "http" {
    address        = "https://gitlab.com/api/v4/projects/86968566/terraform/state/galena-dns"
    lock_address   = "https://gitlab.com/api/v4/projects/86968566/terraform/state/galena-dns/lock"
    unlock_address = "https://gitlab.com/api/v4/projects/86968566/terraform/state/galena-dns/lock"
    lock_method    = "POST"
    unlock_method  = "DELETE"

    # GitLab holds the lock for the whole of an apply, so a second operator
    # arriving mid-apply waits and retries instead of failing at once.
    retry_wait_min = 5
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
  # When either knob is on these are null, so the normal credential chain
  # (AWS_PROFILE, env vars, SSO) applies as usual. Both have to be named here:
  # manage_caa_record alone would otherwise be handed the placeholder and fail
  # against the real zone, which reads as a credential problem rather than as
  # this expression being out of date.
  access_key = var.manage_dns_records || var.manage_caa_record ? null : "unused-placeholder"
  secret_key = var.manage_dns_records || var.manage_caa_record ? null : "unused-placeholder"

  # Skip the eager STS pre-flight. Real API calls still fail loudly on bad
  # credentials; this only stops the provider probing at configure time.
  skip_credentials_validation = true
  skip_requesting_account_id  = true
}
