# Stable public addresses, independent of the servers that hold them.
#
# Every Hetzner server's public address is already a Primary IP object. By
# default Hetzner creates it alongside the server with auto_delete = true, so it
# lives and dies with that one server: replacing a node for any reason — a
# rebuild, a server type change, a corrupted disk — gives it a new address.
# Clients that use the hostname never notice, because Route 53 follows. Clients
# configured by IP (Windows, routers, systemd-resolved; see README "Client
# setup") silently break, and there is no way to reach them to say so.
#
# Declaring the addresses here with auto_delete = false decouples them. A server
# replacement now unassigns the address, destroys the old server, and assigns
# the SAME address to the new one.
#
# What this does not buy: a Primary IP is bound to its location. Moving a node
# from fsn1 to nbg1 is a new address no matter what, because the address is
# routed to that site.
#
# Cost: nothing extra while assigned — the per-node $0.60/month IPv4 charge in
# outputs.tf IS this Primary IP, and IPv6 Primary IPs are not billed at all. An
# UNASSIGNED IPv4 keeps billing at $0.60/month, which is the price of keeping an
# address alive while no server holds it.

resource "hcloud_primary_ip" "ipv4" {
  for_each = var.nodes

  name     = "${var.project_name}-${each.key}-v4"
  type     = "ipv4"
  location = each.value.location

  # The point of this file. Hetzner's own docs recommend against true for the
  # same reason: a server deletion would take the address with it.
  auto_delete = false

  # Belt and braces: an explicit delete — from the provider, a stray
  # `terraform destroy`, or the console — errors instead of releasing an address
  # clients may have typed in. `make destroy` has to lift this deliberately.
  delete_protection = true

  labels = merge(local.common_labels, { node = each.key })
}

resource "hcloud_primary_ip" "ipv6" {
  for_each = var.nodes

  name              = "${var.project_name}-${each.key}-v6"
  type              = "ipv6"
  location          = each.value.location
  auto_delete       = false
  delete_protection = true

  labels = merge(local.common_labels, { node = each.key })
}
