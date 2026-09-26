resource "hcloud_server" "node" {
  for_each = var.nodes

  name        = "${var.project_name}-${each.key}"
  server_type = each.value.server_type
  location    = each.value.location
  image       = var.image
  ssh_keys    = [hcloud_ssh_key.admin.id]

  firewall_ids = [hcloud_firewall.dns.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.yaml.tftpl", {
    node_env                = local.node_env
    rpz_manifest            = local.rpz_manifest
    journal_runtime_max_use = var.journal_runtime_max_use
  })

  labels = merge(local.common_labels, {
    node = each.key
    role = "resolver"
  })

  lifecycle {
    # user_data only takes effect on first boot, so Terraform must not offer to
    # destroy and recreate a live resolver because a template comment changed.
    # Config changes belong to `make deploy`.
    ignore_changes = [user_data]

    precondition {
      condition     = length(templatefile("${path.module}/templates/bootstrap.yaml.tftpl", { node_env = local.node_env, rpz_manifest = local.rpz_manifest, journal_runtime_max_use = var.journal_runtime_max_use })) < 32768
      error_message = "Rendered cloud-init exceeds Hetzner's 32 KiB user_data limit. Move configuration into node/ and let `make deploy` install it."
    }
  }
}
