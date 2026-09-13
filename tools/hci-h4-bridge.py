#!/usr/bin/python3
# hci-h4-bridge: a Linux host's Bluetooth controller as an H4 stream on
# a TCP port, for bt9p on a hosted emu:
#
#   sudo ./tools/hci-h4-bridge.py 0 5555          # hci0, listen on 127.0.0.1:5555
#   ./emu/Linux/o.emu -r. sh -c 'bt9p -t tcp!127.0.0.1!5555; echo up > /net/bt/ctl; cat /net/bt/scan'
#
# Linux's HCI_CHANNEL_USER hands the raw controller to one process:
# every packet on the socket carries its H4 indicator byte, exactly
# what a UART would carry, so the bridge is a relay and nothing more.
# It needs CAP_NET_ADMIN, and the device DOWN and unclaimed by
# bluetoothd (hciconfig hci0 down; or stop bluetooth.service) -- the
# kernel refuses the user channel otherwise. While it runs, bluetoothd
# cannot see the controller; when it exits, the kernel gives it back.
#
# This is a development loop for the HCI layers of docs/BLUETOOTH.md
# (M2, M4-M7) against real silicon with no board. It proves nothing
# about the CYW43455 or the PL011; that is M3, on the Pi.
#
# Uses /usr/bin/python3 deliberately: the system interpreter is the one
# built with AF_BLUETOOTH; a conda python may not be.

import socket, sys, select, errno, ctypes, struct

HCI_CHANNEL_USER = 1

def bind_user_channel(sock, dev):
    # struct sockaddr_hci { sa_family_t hci_family; unsigned short hci_dev, hci_channel; }
    # Python before 3.13 can only bind a raw HCI socket with (dev,), so
    # the user channel is asked for through libc directly.
    libc = ctypes.CDLL(None, use_errno=True)
    addr = struct.pack("HHH", socket.AF_BLUETOOTH, dev, HCI_CHANNEL_USER)
    if libc.bind(sock.fileno(), addr, len(addr)) != 0:
        e = ctypes.get_errno()
        raise OSError(e, "bind: " + errno.errorcode.get(e, str(e)))

def hdrlen(kind):
    return {1: 3, 2: 4, 3: 3, 4: 2, 5: 4}.get(kind, -1)

def paylen(kind, b):
    if kind in (1, 3):
        return b[3]
    if kind == 2:
        return b[3] | (b[4] << 8)
    if kind == 4:
        return b[2]
    if kind == 5:
        return (b[3] | (b[4] << 8)) & 0x3fff
    return -1

class Deframer:
    def __init__(self):
        self.buf = bytearray()
    def feed(self, data):
        self.buf += data
        out = []
        while self.buf:
            kind = self.buf[0]
            hl = hdrlen(kind)
            if hl < 0:
                del self.buf[0]
                continue
            if len(self.buf) < 1 + hl:
                break
            total = 1 + hl + paylen(kind, self.buf)
            if len(self.buf) < total:
                break
            out.append(bytes(self.buf[:total]))
            del self.buf[:total]
        return out

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: hci-h4-bridge.py <hci-index> <tcp-port>")
    dev, port = int(sys.argv[1]), int(sys.argv[2])

    try:
        hci = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
        bind_user_channel(hci, dev)
    except OSError as e:
        if e.errno in (errno.EPERM, errno.EACCES):
            sys.exit("hci-h4-bridge: the user channel needs CAP_NET_ADMIN: run with sudo")
        if e.errno == errno.EBUSY:
            sys.exit("hci-h4-bridge: hci%d is up or held by bluetoothd: hciconfig hci%d down first" % (dev, dev))
        raise

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    print("hci-h4-bridge: hci%d on 127.0.0.1:%d; bt9p -t tcp!127.0.0.1!%d" % (dev, port, port), flush=True)

    while True:
        conn, _ = srv.accept()
        print("hci-h4-bridge: client connected", flush=True)
        d = Deframer()
        ncmd = nevt = 0
        try:
            while True:
                r, _, _ = select.select([conn, hci], [], [])
                if conn in r:
                    data = conn.recv(4096)
                    if not data:
                        break
                    for pkt in d.feed(data):
                        hci.send(pkt)
                        ncmd += 1
                if hci in r:
                    pkt = hci.recv(4096)
                    if not pkt:
                        break
                    conn.sendall(pkt)
                    nevt += 1
        except (ConnectionError, OSError) as e:
            print("hci-h4-bridge: %s" % e, flush=True)
        finally:
            conn.close()
            print("hci-h4-bridge: client gone after %d packets out, %d in" % (ncmd, nevt), flush=True)

if __name__ == "__main__":
    main()
