#!/usr/bin/env python3
"""Raw-wire regressions for the native IPv4 fragment and TCP reseq fixes."""

import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time


GUEST_MAC = bytes.fromhex("525400123456")
PEER_MAC = bytes.fromhex("525400aabbcc")
GUEST_IP = socket.inet_aton("10.0.2.15")
PEER_IP = socket.inet_aton("10.0.2.2")


def checksum(data):
    if len(data) & 1:
        data += b"\0"
    words = struct.unpack("!%dH" % (len(data) // 2), data)
    total = sum(words)
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def eth(payload, etype=0x0800, dst=GUEST_MAC, src=PEER_MAC):
    frame = dst + src + struct.pack("!H", etype) + payload
    return frame + bytes(max(0, 60 - len(frame)))


def ipv4(payload, proto, ident, frag=0, src=PEER_IP, dst=GUEST_IP,
         claimed=None, vihl=0x45):
    total = 20 + len(payload) if claimed is None else claimed
    hdr = struct.pack("!BBHHHBBH4s4s", vihl, 0, total, ident, frag,
                      64, proto, 0, src, dst)
    hdr = hdr[:10] + struct.pack("!H", checksum(hdr)) + hdr[12:]
    return hdr + payload


def udp(payload, sport, dport, src=PEER_IP, dst=GUEST_IP):
    # A zero UDP checksum is valid for IPv4.
    return struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload


def tcp(payload, sport, dport, seq, ack, flags, window=65535, data_offset=5):
    hdr = struct.pack("!HHIIBBHHH", sport, dport, seq, ack,
                      data_offset << 4, flags, window, 0, 0)
    pseudo = PEER_IP + GUEST_IP + bytes((0, 6)) + struct.pack("!H", len(hdr) + len(payload))
    csum = checksum(pseudo + hdr + payload)
    return hdr[:16] + struct.pack("!H", csum) + hdr[18:] + payload


def dhcp_type(packet):
    if len(packet) < 14 + 20 + 8 + 240 or packet[12:14] != b"\x08\x00":
        return None, None
    ihl = (packet[14] & 15) * 4
    if packet[23] != 17:
        return None, None
    u = 14 + ihl
    if packet[u:u + 4] != struct.pack("!HH", 68, 67):
        return None, None
    bootp = packet[u + 8:]
    if len(bootp) < 240 or bootp[236:240] != b"\x63\x82\x53\x63":
        return None, None
    opts = bootp[240:]
    i = 0
    while i < len(opts):
        code = opts[i]
        i += 1
        if code == 255:
            break
        if code == 0:
            continue
        if i >= len(opts):
            break
        n = opts[i]
        i += 1
        if code == 53 and n == 1 and i < len(opts):
            return opts[i], bootp
        i += n
    return None, bootp


def dhcp_reply(request, kind):
    b = bytearray(240)
    b[0:4] = bytes((2, 1, 6, 0))
    b[4:8] = request[4:8]
    b[10:12] = request[10:12]
    b[16:20] = GUEST_IP
    b[20:24] = PEER_IP
    b[28:44] = request[28:44]
    b[236:240] = b"\x63\x82\x53\x63"
    opts = (bytes((53, 1, kind, 54, 4)) + PEER_IP +
            bytes((1, 4)) + socket.inet_aton("255.255.255.0") +
            bytes((3, 4)) + PEER_IP +
            bytes((51, 4)) + struct.pack("!I", 3600) + bytes((255,)))
    body = bytes(b) + opts
    return eth(ipv4(udp(body, 67, 68, PEER_IP, b"\xff" * 4), 17, 1,
                    src=PEER_IP, dst=b"\xff" * 4), dst=b"\xff" * 6)


def arp_reply():
    body = struct.pack("!HHBBH", 1, 0x0800, 6, 4, 2)
    body += PEER_MAC + PEER_IP + GUEST_MAC + GUEST_IP
    return eth(body, 0x0806)


class Harness:
    def __init__(self, qemu, image):
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        base = 20000 + (os.getpid() % 20000) * 2
        self.peer = ("127.0.0.1", base + 1)
        self.rx.bind(("127.0.0.1", base))
        self.rx.settimeout(0.2)
        net = "socket,id=n0,udp=127.0.0.1:%d,localaddr=127.0.0.1:%d" % (base, base + 1)
        args = [qemu, "-M", "virt", "-cpu", "cortex-a53", "-smp", "4",
                "-m", "1024", "-device", "virtio-rng-device", "-device",
                "qemu-xhci", "-kernel", image, "-display", "none", "-serial",
                "stdio", "-netdev", net, "-device",
                "virtio-net-device,netdev=n0,mac=52:54:00:12:34:56"]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        self.console = bytearray()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            b = self.p.stdout.read(1)
            if not b:
                return
            self.console.extend(b)

    def send(self, frame):
        self.rx.sendto(frame, self.peer)

    def recv(self, deadline):
        while time.monotonic() < deadline:
            try:
                frame = self.rx.recv(65535)
            except socket.timeout:
                continue
            # Keep the peer's address warm for every guest ARP request.
            if len(frame) >= 42 and frame[12:14] == b"\x08\x06" and frame[20:22] == b"\x00\x01":
                self.send(arp_reply())
            return frame
        return None

    def wait_console(self, text, seconds):
        needle = text.encode()
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if needle in self.console:
                return True
            time.sleep(0.1)
        return False

    def command(self, command):
        self.p.stdin.write(command.encode() + b"\r")
        self.p.stdin.flush()

    def ipstat(self, name):
        start = len(self.console)
        self.command("echo NETSEC-STATS; cat /net/ipifc/stats; echo NETSEC-END")
        end = time.monotonic() + 4
        while time.monotonic() < end:
            tail = bytes(self.console[start:])
            # The serial console echoes the command before executing it.  Do
            # not mistake the echoed "echo NETSEC-END" argument for the
            # marker printed on its own line after cat has completed.
            if re.search(rb"(?:^|\r?\n)NETSEC-END(?:\r?\n|$)", tail):
                match = re.search(rb"(?:^|\r?\n)" + name.encode() + rb": ([0-9]+)", tail)
                if match:
                    return int(match.group(1))
                raise RuntimeError("IP statistic %s was not reported" % name)
            time.sleep(0.05)
        raise RuntimeError("timed out reading IP statistics")

    def close(self):
        self.p.kill()
        self.p.wait()


def configure(h):
    end = time.monotonic() + 90
    offered = False
    while time.monotonic() < end:
        frame = h.recv(end)
        if frame is None:
            break
        kind, req = dhcp_type(frame)
        if kind == 1:
            h.send(dhcp_reply(req, 2))
            offered = True
        elif kind == 3 and offered:
            h.send(dhcp_reply(req, 5))
            break
    if not h.wait_console("10.0.2.15 mask 255.255.255.0", 20):
        raise RuntimeError("DHCP did not configure the guest")
    h.send(arp_reply())


def icmp_regression(h):
    data = bytes(range(24))
    icmp = struct.pack("!BBHHH", 8, 0, 0, 0x1234, 1) + data
    icmp = icmp[:2] + struct.pack("!H", checksum(icmp)) + icmp[4:]

    # A valid two-fragment request remains functional.
    h.send(eth(ipv4(icmp[:24], 1, 0x4100, 0x2000)))
    h.send(eth(ipv4(icmp[24:], 1, 0x4100, 3)))
    end = time.monotonic() + 3
    valid = False
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None or len(f) < 42 or f[12:14] != b"\x08\x00":
            continue
        if f[23] == 1 and f[34] == 0 and struct.unpack("!H", f[38:40])[0] == 0x1234:
            valid = True
            break
    if not valid:
        raise RuntimeError("valid fragmented ICMP request was not answered")
    print("FRAGMENT-VALID-PASS", flush=True)

    # DF is a flag, not evidence of fragmentation.  A complete DF packet
    # sharing an id with a queued fragmented datagram must not discard that
    # queue; the remaining fragment still has to complete afterwards.
    queued = struct.pack("!BBHHH", 8, 0, 0, 0x2345, 2) + data
    queued = queued[:2] + struct.pack("!H", checksum(queued)) + queued[4:]
    dficmp = struct.pack("!BBHHH", 8, 0, 0, 0x7777, 3) + data
    dficmp = dficmp[:2] + struct.pack("!H", checksum(dficmp)) + dficmp[4:]
    h.send(eth(ipv4(queued[:24], 1, 0x4104, 0x2000)))
    h.send(eth(ipv4(dficmp, 1, 0x4104, 0x4000)))
    end = time.monotonic() + 3
    dfreply = False
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None or len(f) < 42 or f[12:14] != b"\x08\x00":
            continue
        if f[23] == 1 and f[34] == 0 and struct.unpack("!H", f[38:40])[0] == 0x7777:
            dfreply = True
            break
    if not dfreply:
        raise RuntimeError("complete IPv4 DF control was not answered")
    h.send(eth(ipv4(queued[24:], 1, 0x4104, 3)))
    end = time.monotonic() + 3
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None or len(f) < 42 or f[12:14] != b"\x08\x00":
            continue
        if f[23] == 1 and f[34] == 0 and struct.unpack("!H", f[38:40])[0] == 0x2345:
            print("FRAGMENT-DF-PASS", flush=True)
            break
    else:
        raise RuntimeError("DF-only packet discarded another datagram's fragment queue")

    failures = h.ipstat("ReasmFails")
    header_errors = h.ipstat("InHdrErrors")

    # Same bytes, but the last fragment claims another 1000 bytes. It must be
    # rejected before the reassembly queue can extend a Block to that claim.
    h.send(eth(ipv4(icmp[:24], 1, 0x4101, 0x2000)))
    h.send(eth(ipv4(icmp[24:], 1, 0x4101, 3, claimed=1028)))
    end = time.monotonic() + 2
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None or len(f) < 42 or f[12:14] != b"\x08\x00":
            continue
        if f[23] == 1 and f[34] == 0 and struct.unpack("!H", f[38:40])[0] == 0x1234:
            total = struct.unpack("!H", f[16:18])[0]
            raise RuntimeError("lying fragment produced a %d-byte ICMP reply" % total)
    # The hardened ingress path rejects a total length larger than the
    # received frame before reassembly.  Keep accepting ReasmFails as well so
    # this regression remains valid if the check is later moved into the
    # reassembler; the security property is rejection before upper layers.
    if (h.ipstat("ReasmFails") <= failures and
            h.ipstat("InHdrErrors") <= header_errors):
        raise RuntimeError("lying fragment was not rejected at IPv4 ingress")
    print("FRAGMENT-LIE-PASS", flush=True)

    # ipcsum derives its read length from IHL. A 60-byte IHL in a received
    # frame whose IP block is shorter must be rejected before checksuming.
    errors = h.ipstat("InHdrErrors")
    h.send(eth(ipv4(icmp, 1, 0x4102, claimed=20 + len(icmp), vihl=0x4F)))
    time.sleep(0.5)
    if h.ipstat("InHdrErrors") <= errors:
        raise RuntimeError("oversized IPv4 IHL was not rejected at ingress")
    print("IPV4-IHL-PASS", flush=True)

    # Link-layer bytes beyond the declared IPv4 total are padding, not input
    # to an upper-layer protocol.
    padded = icmp + bytes(range(64))
    h.send(eth(ipv4(padded, 1, 0x4103, claimed=20 + len(icmp))))
    end = time.monotonic() + 2
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None or len(f) < 42 or f[12:14] != b"\x08\x00":
            continue
        if f[23] == 1 and f[34] == 0 and struct.unpack("!H", f[38:40])[0] == 0x1234:
            total = struct.unpack("!H", f[16:18])[0]
            if total != 20 + len(icmp):
                raise RuntimeError("IPv4 padding reached ICMP reply (%d bytes)" % total)
            print("IPV4-TRIM-PASS", flush=True)
            break
    else:
        raise RuntimeError("padded IPv4 control was not answered")


def parse_tcp(frame, dport):
    if len(frame) < 54 or frame[12:14] != b"\x08\x00" or frame[23] != 6:
        return None
    ihl = (frame[14] & 15) * 4
    off = 14 + ihl
    sport, gotd, seq, ack = struct.unpack("!HHII", frame[off:off + 12])
    if gotd != dport:
        return None
    return sport, seq, ack, frame[off + 13]


def tcp_regression(h):
    sport, dport = 40000, 8700
    h.command("listen -A 'tcp!*!8702' {cat > /dev/null} &")
    time.sleep(1)
    synseq = 1000
    h.send(eth(ipv4(tcp(b"", sport, dport, synseq, 0, 0x02), 6, 0x5000)))
    end = time.monotonic() + 4
    synack = None
    while time.monotonic() < end:
        f = h.recv(end)
        if f is None:
            break
        t = parse_tcp(f, sport)
        if t is not None and t[3] & 0x12 == 0x12:
            synack = t
            break
    if synack is None:
        raise RuntimeError("TCP listener did not answer SYN")
    guestseq = synack[1]
    seq = synseq + 1
    h.send(eth(ipv4(tcp(b"", sport, dport, seq, guestseq + 1, 0x10), 6, 0x5001)))

    # One-byte descending segments maximize Blocks per byte and exercise the
    # old head-insertion bypass. The patched queue must flush at its
    # MSS-derived packet limit and log the bound before all 512 arrive.
    for n in range(512, 0, -1):
        segment = tcp(b"x", sport, dport, seq + n, guestseq + 1, 0x18)
        h.send(eth(ipv4(segment, 6, 0x5100 + (n & 0xFF))))
    if not h.wait_console("resequence queue limit:", 8):
        raise RuntimeError("descending TCP segments did not hit a reseq limit")
    print("TCP-RESEQ-LIMIT-PASS", flush=True)


def malformed_transport_regression(h):
    # 9front 7838d689: transport lengths smaller than their headers used to
    # reach trimblock with a negative/underflowed size.  A listening UDP
    # conversation is required to reach the vulnerable post-lookup path.
    h.command("listen -A 'udp!*!8701' {cat > /dev/null} &")
    h.command("listen -A 'tcp!*!8700' {cat > /dev/null} &")
    time.sleep(1)
    short_udp = struct.pack("!HHHH", 40001, 8701, 4, 0)
    h.send(eth(ipv4(short_udp, 17, 0x5200)))

    # The actual TCP segment is 20 bytes, but data offset claims 60.  It must
    # be rejected before the declared header length is subtracted.
    bad_tcp = tcp(b"", 40002, 8702, 1, 0, 0x02, data_offset=15)
    h.send(eth(ipv4(bad_tcp, 6, 0x5201)))
    time.sleep(0.5)
    h.command("echo TRANSPORT-BOUNDS-PASS")
    if not h.wait_console("TRANSPORT-BOUNDS-PASS", 3):
        raise RuntimeError("malformed transport length stopped the guest")
    print("TRANSPORT-BOUNDS-PASS", flush=True)


def negative_devip_attach_regression(h):
    h.command("bind '#I-1' /net.alt")
    time.sleep(0.5)
    h.command("echo DEVIP-NEGATIVE-PASS")
    if not h.wait_console("DEVIP-NEGATIVE-PASS", 3):
        raise RuntimeError("negative IP device attach stopped the guest")
    print("DEVIP-NEGATIVE-PASS", flush=True)


def main():
    if len(sys.argv) != 3:
        print("usage: qemu_net_security.py qemu kernel.img", file=sys.stderr)
        return 2
    h = Harness(sys.argv[1], sys.argv[2])
    try:
        if not h.wait_console("init: starting the shell", 90):
            raise RuntimeError("guest did not reach its shell")
        configure(h)
        failures = []
        for name, test in (("fragment", icmp_regression),
                           ("transport", malformed_transport_regression),
                           ("devip", negative_devip_attach_regression),
                           ("tcp", tcp_regression)):
            try:
                test(h)
            except Exception as exc:
                failures.append("%s: %s" % (name, exc))
        if failures:
            raise RuntimeError("; ".join(failures))
        return 0
    except Exception as exc:
        print("FAIL:", exc, file=sys.stderr)
        print(bytes(h.console[-2000:]).decode(errors="replace"), file=sys.stderr)
        return 1
    finally:
        h.close()


if __name__ == "__main__":
    raise SystemExit(main())
