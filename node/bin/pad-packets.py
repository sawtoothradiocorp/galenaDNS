#!/usr/bin/env python3
"""Watch plaintext-sized TLS records leaving for the configured upstreams.

pad-queries rounds each DNS message to a multiple of 128 bytes before unbound
wraps it in DNS-over-TLS. Two names that differ by a few dozen bytes, and that
both sit inside one block, therefore leave as the same number of bytes on the
wire. This program reports those sizes. It never writes packet contents, and
the names themselves are inside TLS, so they are not visible here.

`capture` prints one TCP payload length per line for TLS application-data
records addressed to the given upstreams on port 853, until SIGTERM.

`classify` reads those lengths and prints one line: pass, fail, or warn, then
a tab, then the reason. A single size (or two sizes a whole block apart) is
padding working. Two sizes apart by about the extra label is padding absent.
Anything else is not evidence either way.

`--self-test` checks the parser and the classifier without a network.
"""

import argparse
import ipaddress
import signal
import socket
import struct
import sys
from collections import Counter

ETH_P_ALL = 0x0003
TLS_APPLICATION_DATA = 23


def tcp_appdata_len(frame, dests):
    """Return the TCP payload length of one complete TLS application-data
    record addressed to `dests` on port 853, or None."""
    if len(frame) < 14:
        return None
    ethertype = struct.unpack("!H", frame[12:14])[0]
    offset = 14
    if ethertype == 0x8100:
        if len(frame) < 18:
            return None
        ethertype = struct.unpack("!H", frame[16:18])[0]
        offset = 18
    if ethertype == 0x0800:
        parsed = _ipv4(frame, offset)
    elif ethertype == 0x86DD:
        parsed = _ipv6(frame, offset)
    else:
        return None
    if parsed is None:
        return None
    dst, payload = parsed
    if dst not in dests or len(payload) < 5 or payload[0] != TLS_APPLICATION_DATA:
        return None
    record_len = struct.unpack("!H", payload[3:5])[0]
    # One record, filling the segment. A split or coalesced segment is not a
    # size we can compare, so the caller treats it as unseen.
    if record_len < 1 or len(payload) != 5 + record_len:
        return None
    return len(payload)


def _ipv4(frame, offset):
    if len(frame) < offset + 20:
        return None
    ver_ihl = frame[offset]
    if ver_ihl >> 4 != 4:
        return None
    ihl = (ver_ihl & 0x0F) * 4
    if ihl < 20 or len(frame) < offset + ihl:
        return None
    total = struct.unpack("!H", frame[offset + 2 : offset + 4])[0]
    if frame[offset + 9] != socket.IPPROTO_TCP:
        return None
    if total < ihl or offset + total > len(frame):
        return None
    dst = ipaddress.IPv4Address(frame[offset + 16 : offset + 20])
    return _tcp(frame[offset + ihl : offset + total], dst)


def _ipv6(frame, offset):
    if len(frame) < offset + 40:
        return None
    if frame[offset] >> 4 != 6:
        return None
    payload_len = struct.unpack("!H", frame[offset + 4 : offset + 6])[0]
    if frame[offset + 6] != socket.IPPROTO_TCP:
        return None
    end = offset + 40 + payload_len
    if end > len(frame):
        return None
    dst = ipaddress.IPv6Address(frame[offset + 24 : offset + 40])
    return _tcp(frame[offset + 40 : end], dst)


def _tcp(segment, dst):
    if len(segment) < 20:
        return None
    dport = struct.unpack("!H", segment[2:4])[0]
    if dport != 853:
        return None
    data_off = (segment[12] >> 4) * 4
    if data_off < 20 or data_off > len(segment):
        return None
    return dst, segment[data_off:]


def classify(lengths, block=128, name_gap=48):
    """Decide whether the observed sizes are padded queries."""
    lengths = [n for n in lengths if isinstance(n, int) and n > 0]
    n = len(lengths)
    if n < 6:
        return "warn", "saw %d upstream packets, need at least 6" % n
    ranked = Counter(lengths).most_common()
    top_len, top_n = ranked[0]
    if top_n >= 6 and top_n / n >= 0.75:
        return "pass", "%d packets, %d of them %d bytes" % (n, top_n, top_len)
    if len(ranked) >= 2:
        (a, ac), (b, bc) = ranked[0], ranked[1]
        gap = abs(a - b)
        if ac >= 3 and bc >= 3 and gap != 0 and gap % block == 0:
            return (
                "pass",
                "%d packets at %d and %d bytes, %d apart (a multiple of the %d-byte block)"
                % (n, a, b, gap, block),
            )
        lo, hi = name_gap // 2, name_gap + name_gap // 2
        if ac >= 3 and bc >= 3 and lo <= gap <= hi:
            return (
                "fail",
                "short and long names left at %d and %d bytes (%d apart; the extra label is %d)"
                % (a, b, gap, name_gap),
            )
    shown = ", ".join("%dx%d" % (length, count) for length, count in ranked[:6])
    return "warn", "ambiguous packet sizes: %s" % shown


def _capture(dests):
    """Read frames until SIGTERM. The caller kills us once its queries are done."""
    try:
        sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(ETH_P_ALL))
    except OSError as exc:
        print("cannot open a packet socket: %s" % exc, file=sys.stderr)
        return 2
    sock.settimeout(0.3)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    except OSError:
        pass

    def _stop(_signum, _frame):
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, _stop)
    try:
        while True:
            try:
                frame = sock.recv(65535)
            except socket.timeout:
                continue
            except InterruptedError:
                break
            n = tcp_appdata_len(frame, dests)
            if n is not None:
                print(n, flush=True)
    finally:
        sock.close()
    return 0


def _self_test():
    def ipv4_frame(dst, payload, dport=853, vlan=False):
        eth = b"\x00" * 12
        if vlan:
            eth += struct.pack("!HHH", 0x8100, 1, 0x0800)
        else:
            eth += struct.pack("!H", 0x0800)
        src = socket.inet_aton("203.0.113.10")
        dst_b = socket.inet_aton(dst)
        ihl = 20
        total = ihl + 20 + len(payload)
        ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, total, 0, 0, 64, 6, 0, src, dst_b)
        tcp = struct.pack("!HHIIBBHHH", 40000, dport, 1, 0, 5 << 4, 0x18, 65535, 0, 0)
        return eth + ip + tcp + payload

    def ipv6_frame(dst, payload):
        eth = b"\x00" * 12 + struct.pack("!H", 0x86DD)
        src = socket.inet_pton(socket.AF_INET6, "2001:db8::10")
        dst_b = socket.inet_pton(socket.AF_INET6, dst)
        ip = struct.pack("!IHBB16s16s", 0x60000000, 20 + len(payload), 6, 64, src, dst_b)
        tcp = struct.pack("!HHIIBBHHH", 40000, 853, 1, 0, 5 << 4, 0x18, 65535, 0, 0)
        return eth + ip + tcp + payload

    def record(n):
        # content-type, version, length, body
        return struct.pack("!BHH", TLS_APPLICATION_DATA, 0x0303, n) + (b"\x00" * n)

    dests = {ipaddress.ip_address("9.9.9.9"), ipaddress.ip_address("2620:fe::fe")}
    body = record(40)
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", body), dests) == len(body)
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", body, vlan=True), dests) == len(body)
    assert tcp_appdata_len(ipv6_frame("2620:fe::fe", body), dests) == len(body)
    assert tcp_appdata_len(ipv4_frame("1.1.1.1", body), dests) is None
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", body, dport=53), dests) is None
    handshake = struct.pack("!BHH", 22, 0x0303, 40) + (b"\x00" * 40)
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", handshake), dests) is None
    split = record(40)[:20]
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", split), dests) is None
    coalesced = record(40) + record(40)
    assert tcp_appdata_len(ipv4_frame("9.9.9.9", coalesced), dests) is None

    assert classify([180] * 8)[0] == "pass"
    assert classify([180] * 7 + [228])[0] == "pass"
    assert classify([180] * 4 + [228] * 4)[0] == "fail"
    assert classify([180] * 4 + [308] * 4)[0] == "pass"  # 128 bytes: next block
    assert classify([180] * 3)[0] == "warn"
    assert classify([180, 200, 220, 240] * 2)[0] == "warn"
    print("self-test ok")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    cap = sub.add_parser("capture")
    cap.add_argument("--dest-ip", action="append", required=True)

    clf = sub.add_parser("classify")
    clf.add_argument("--name-gap", type=int, default=48)
    clf.add_argument("--block", type=int, default=128)

    sub.add_parser("self-test")
    args = parser.parse_args(argv)

    if args.cmd == "self-test":
        return _self_test()
    if args.cmd == "classify":
        lengths = []
        for line in sys.stdin:
            line = line.strip()
            if line.isdigit():
                lengths.append(int(line))
        verdict, detail = classify(lengths, block=args.block, name_gap=args.name_gap)
        print("%s\t%s" % (verdict, detail))
        return 0

    dests = set()
    for text in args.dest_ip:
        dests.add(ipaddress.ip_address(text))
    return _capture(dests)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
