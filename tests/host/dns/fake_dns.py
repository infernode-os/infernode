#!/usr/bin/env python3
"""A scripted DNS server for tests/host/dns_reply_test.sh.

Listens on UDP 127.0.0.1 at a port of the system's choosing, prints the port,
and answers by the first label of the name asked:

  good*      an A record, 192.0.2.1
  bigttl     an A record with the largest TTL a reply can carry
  rcode6     no records, response code 6
  shorta     an A record whose data is two bytes long
  overrun    an MX record whose data length is shorter than its fields
  otherq     first a reply to a different question, then the real one
  wrongport  first a reply from another port, then the real one

The last two send the reply that must be ignored first and the right one a
moment later, so a resolver that takes the first has the wrong address.
"""
import socket
import struct
import sys
import threading
import time

GOOD = bytes([192, 0, 2, 1])
WRONG_Q = bytes([198, 51, 100, 66])
WRONG_PORT = bytes([198, 51, 100, 77])


def name(labels):
    out = b""
    for l in labels:
        out += bytes([len(l)]) + l
    return out + b"\0"


def parse_question(pkt):
    labels, o = [], 12
    while pkt[o] != 0:
        n = pkt[o]
        labels.append(pkt[o + 1:o + 1 + n])
        o += 1 + n
    qtype, qclass = struct.unpack("!HH", pkt[o + 1:o + 5])
    return labels, qtype, qclass, pkt[12:o + 5]


def header(qid, rcode, an):
    # response, recursion desired and available
    return struct.pack("!HHHHHH", qid, 0x8180 | rcode, 1, an, 0, 0)


def rr(owner, rtype, ttl, data, rdlen=None):
    if rdlen is None:
        rdlen = len(data)
    return owner + struct.pack("!HHIH", rtype, 1, ttl, rdlen) + data


def a_reply(qid, question, labels, addr, ttl=60):
    return header(qid, 0, 1) + question + rr(name(labels), 1, ttl, addr)


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    other = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    other.bind(("127.0.0.1", 0))
    print(s.getsockname()[1], flush=True)

    def later(sock, pkt, peer, delay=0.3):
        def send():
            time.sleep(delay)
            sock.sendto(pkt, peer)
        threading.Thread(target=send, daemon=True).start()

    while True:
        pkt, peer = s.recvfrom(4096)
        if len(pkt) < 17:
            continue
        qid = struct.unpack("!H", pkt[:2])[0]
        try:
            labels, qtype, qclass, question = parse_question(pkt)
        except (IndexError, struct.error):
            continue
        first = labels[0].decode("ascii", "replace") if labels else ""
        good = a_reply(qid, question, labels, GOOD)

        if first.startswith("good"):
            s.sendto(good, peer)
        elif first == "bigttl":
            s.sendto(a_reply(qid, question, labels, GOOD, ttl=0x7FFFFFFF), peer)
        elif first == "rcode6":
            s.sendto(header(qid, 6, 0) + question, peer)
        elif first == "shorta":
            s.sendto(header(qid, 0, 1) + question + rr(name(labels), 1, 60, GOOD[:2]), peer)
        elif first == "overrun":
            # MX: preference and a 13-byte name, declared as three bytes of data
            data = struct.pack("!H", 10) + name([b"mail", b"example"])
            s.sendto(header(qid, 0, 1) + question + rr(name(labels), 15, 60, data, rdlen=3), peer)
        elif first == "otherq":
            evil = name([b"evil", b"test"]) + struct.pack("!HH", qtype, qclass)
            s.sendto(header(qid, 0, 1) + evil + rr(name([b"evil", b"test"]), 1, 60, WRONG_Q), peer)
            later(s, good, peer)
        elif first == "wrongport":
            other.sendto(a_reply(qid, question, labels, WRONG_PORT), peer)
            later(s, good, peer)
        else:
            s.sendto(header(qid, 3, 0) + question, peer)


if __name__ == "__main__":
    sys.exit(main())
