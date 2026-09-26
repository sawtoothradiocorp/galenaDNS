# Hetzner Cloud Firewall. This runs in front of the VM, so a misconfigured host
# ruleset cannot expose a port it does not allow. The host nftables ruleset
# mirrors it — defence in depth, and the audit script checks both.
#
# No outbound rules are declared, which leaves egress unrestricted. That is
# required: full recursion means talking to authoritative servers on port 53.
resource "hcloud_firewall" "dns" {
  name   = "${var.project_name}-fw"
  labels = local.common_labels

  # DoH (HTTP/2) and DoT.
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "DoH"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "853"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "DoT"
  }

  # DoH3 and DoQ both ride QUIC, so these are the UDP halves of the two above.
  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "DoH3 (QUIC)"
  }

  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "853"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "DoQ"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = [var.admin_cidr]
    description = "SSH (admin only)"
  }

  # ICMP is not optional here. QUIC relies on path MTU discovery, and dropping
  # "fragmentation needed" / "packet too big" produces the worst class of bug:
  # DoQ and DoH3 work from most networks and hang from a few.
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP + ICMPv6 (path MTU discovery, required for QUIC)"
  }

  # Port 80 is deliberately absent. ACME uses DNS-01, so no inbound HTTP is
  # needed and no HTTP server ever runs — which also means no access logs.
}
