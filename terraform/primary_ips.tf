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
# address alive while no server holds it — minutes, during a node replacement.
# `make destroy` and removing a node from var.nodes both delete the addresses.

resource "hcloud_primary_ip" "ipv4" {
  for_each = var.nodes

  name     = "${var.project_name}-${each.key}-v4"
  type     = "ipv4"
  location = each.value.location

  # The point of this file. The hcloud provider's own docs recommend against true
  # for the same reason: a server deletion would take the address with it.
  auto_delete = false

  # No delete_protection, deliberately: the only IP-configured clients are the
  # operator's own, so `make destroy` should release these cleanly rather than
  # leave them billing unassigned. Revisit before publishing IP-based setup to
  # anyone else — then an address outliving a destroy is the point. The
  # destructive provider update this file was nearly bitten by is prevented by
  # ignore_changes on the servers' public_net, not by protection.

  labels = merge(local.common_labels, { node = each.key })
}

resource "hcloud_primary_ip" "ipv6" {
  for_each = var.nodes

  name        = "${var.project_name}-${each.key}-v6"
  type        = "ipv6"
  location    = each.value.location
  auto_delete = false

  labels = merge(local.common_labels, { node = each.key })
}
