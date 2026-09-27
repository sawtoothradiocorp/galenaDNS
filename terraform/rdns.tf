# Reverse DNS (PTR) for each node's public addresses.
#
# Every node's PTR is var.domain, the same name clients connect to. With several
# nodes that means several addresses share one PTR target, which is fine: every
# node has its own A/AAAA record under that same name, so a forward-confirmed
# reverse lookup still matches. Per-node names would need
# per-node forward records to stay consistent, which buys nothing here.
#
# This is cosmetic for a resolver — nothing in DoH/DoT/DoQ validates a PTR — but
# it stops abuse-desk tooling and traceroutes from labelling the node
# static.17.3.28.2.clients.your-server.de, and it makes the host identifiable as
# ours rather than as a generic Hetzner VM.
#
# PTRs live at Hetzner, not in Route 53: the reverse zones for these ranges are
# delegated to them, so the Hetzner API (the hcloud provider) is the only way to
# set them. Hetzner refuses a PTR for an address outside the node's assignment, so a
# wrong ip_address here fails loudly at apply rather than going unnoticed.

resource "hcloud_rdns" "ipv4" {
  for_each = hcloud_server.node

  server_id  = each.value.id
  ip_address = each.value.ipv4_address
  dns_ptr    = var.domain
}

resource "hcloud_rdns" "ipv6" {
  for_each = hcloud_server.node

  # The single address the node actually announces (::1 of its /64), which is
  # also the value in the AAAA record. Hetzner would accept a PTR for any
  # address in the /64, but only this one is ever a source address.
  server_id  = each.value.id
  ip_address = each.value.ipv6_address
  dns_ptr    = var.domain
}
