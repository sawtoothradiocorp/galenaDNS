terraform {
  required_version = ">= 1.9.0"

  required_providers {
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
