resource "hcloud_server" "node" {
  for_each = var.nodes

  name        = "${var.project_name}-${each.key}"
  server_type = each.value.server_type
  location    = each.value.location
  image       = var.image
  ssh_keys    = [hcloud_ssh_key.admin.id]

  firewall_ids = [hcloud_firewall.dns.id]

  # Addresses come from primary_ips.tf so they outlive any one server.
  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.ipv4[each.key].id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.ipv6[each.key].id
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
    #
    # public_net is ignored after creation because the provider's in-place update
    # for it is destructive. Adopting the addresses in primary_ips.tf leaves state
    # at ipv4 = 0 while config names the real ID, and hcloud v1.69's
    # updatePublicNet treats that as "replace the auto IP with a managed one": it
    # powers the server off, unassigns the current IP, DELETES it because the old
    # ID in state is 0 — which is the very address being adopted — then fails to
    # assign the ID it just deleted. Both nodes at once, since nothing orders them.
    # Read in the provider source, not tested. Creation still honours public_net,
    # so a replaced server gets the kept addresses; it is only updates that are
    # skipped. To move a node to different addresses, replace the server.
    ignore_changes = [user_data, public_net]

    precondition {
      condition     = length(templatefile("${path.module}/templates/bootstrap.yaml.tftpl", { node_env = local.node_env, rpz_manifest = local.rpz_manifest, journal_runtime_max_use = var.journal_runtime_max_use })) < 32768
      error_message = "Rendered cloud-init exceeds Hetzner's 32 KiB user_data limit. Move configuration into node/ and let `make deploy` install it."
    }
  }
}
