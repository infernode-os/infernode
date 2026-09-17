#!/usr/bin/env python3
"""
Wi-Fi acceptance: hostap's hwsim scenarios, for real, with the tester's
radio as the access point and the board as the station.

The Wi-Fi Alliance's certification is a licensed test bed. hostap's own
test suite (tests/hwsim) is the open battery its supplicant and AP are
held to; each scenario here is named after the hwsim test it stands
in for, run over the air instead of over mac80211_hwsim: an AP of that
kind on the tester's radio (wifi-ap.sh, root, started once), the board
told to join it the way osinit.b does at boot -- factotum key, ip/wpa
-s, ip/dhcp -- and then asked to carry traffic on that link alone.

The AP's subnet (192.168.7.0/24) is not the wired one, so the reply
path is the radio and only the radio: AGENTS.md's warning about two
interfaces on one subnet does not apply, and a board that passes here
has proved its transmit path, not just its receive.

  ap_open              join with no security; DHCP; traffic
  ap_wpa2_psk          WPA2-PSK CCMP; 4-way handshake; group key; DHCP; traffic
  ap_wpa2_psk 5 GHz    the same on channel 36
  ap_hidden_ssid       WPA2 with the SSID not broadcast
  ap_pmf_required      WPA2 with 802.11w required (the station must do MFP or be refused)
  sae                  WPA3-SAE (the station must do SAE or be refused)
  wrong passphrase     the join fails, and says so, and does not wedge the radio
  reassociation        AP down and up again: the station re-joins on its own
  throughput/latency   over the radio alone

A scenario the station does not implement (PMF, SAE today) fails
truthfully: the point of the line is that it is known and written down.
At the end the board is rebooted so it rejoins its usual network.

Before running: sudo tests/acceptance/wifi-ap.sh <tester-radio>
Usage: wifi.py --board 192.168.1.104 [--serial-log ...]
"""
import re, socket, sys, time
from board import Board, run, args

CTL = "/tmp/wifi-ap.ctl"
PASS = "infernode-acceptance"

def ap(cmd):
    with open(CTL, "w") as f:
        f.write(cmd + "\n")
    time.sleep(4)

def station_addr(b):
    """The board's address on the test AP's subnet, if it has one."""
    out = b.sh("cat /net/ipifc/*/status", wait=1.5)
    m = re.search(r"(192\.168\.7\.\d+)", out)
    return m.group(1) if m else None

def wifi_ifc(b):
    out = b.sh("grep -l ether1 /net/ipifc/*/status", wait=1.0)
    m = re.search(r"/net/ipifc/(\d+)/status", out)
    return m.group(1) if m else None

def join(b, ssid, passphrase, timeout=90):
    """Join as osinit.b does; return (authenticated, seconds, log tail)."""
    b.sh("kill Wpa >[2] /dev/null", "kill Dhcp >[2] /dev/null",
         "echo 'delkey proto=wpapsk' > /tmp/factotum/ctl",
         "echo 'key proto=wpapsk role=client essid=%s !password=%s' > /tmp/factotum/ctl" % (ssid, passphrase),
         "echo 'essid default' > /net/ether1/0/ctl",
         "rm -f /tmp/wpa.log",
         "ip/wpa -s %s /net/ether1 >[2] /tmp/wpa.log &" % ssid, wait=0.8)
    t0 = time.time()
    while time.time() - t0 < timeout:
        log = b.sh("cat /tmp/wpa.log", wait=1.0)
        if "group key" in log:
            return True, time.time() - t0, log[-200:]
        if re.search(r"wpa: .*(fail|refused|timed out|did not)", log):
            break
        time.sleep(3)
    return False, time.time() - t0, b.sh("cat /tmp/wpa.log", wait=1.0)[-300:]

def dhcp(b):
    ifc = wifi_ifc(b)
    if ifc is None:
        return None
    b.sh("ip/dhcp /net/ipifc/%s" % ifc, wait=6.0)
    return station_addr(b)

def traffic(b, addr, secs):
    tx, rx, avg = 0, 0, 0.0
    rc, out = run(["ping", "-I", "192.168.7.1", "-c", "30", "-i", "0.1", "-W", "2", addr], timeout=60)
    m = re.search(r"(\d+) packets transmitted, (\d+) received", out)
    if m:
        tx, rx = int(m.group(1)), int(m.group(2))
    m = re.search(r"= [\d.]+/([\d.]+)/", out)
    if m:
        avg = float(m.group(1))
    return tx, rx, avg

def scenario(b, a, name, ssid_name=None, passphrase=PASS, expect_join=True, note=""):
    ssid = "infernode-test-" + (ssid_name or name)
    ap("scenario " + name)
    ok, secs, tail = join(b, ssid, passphrase)
    if not expect_join:
        b.check(not ok, "%s: the join is refused, as it must be%s" % (name, note), "it authenticated")
        st = b.sh("cat /net/ether1/ifstats", wait=1.0)
        b.check("link:" in st and "not loaded" not in st, "%s: the radio is not wedged by the refusal" % name, st.strip()[:120])
        return None
    b.check(ok, "%s: authenticated in %.0fs (4-way handshake, group key installed)%s" % (name, secs, note), tail.strip().replace("\n", " | ")[-200:])
    if not ok:
        return None
    addr = dhcp(b)
    b.check(addr is not None, "%s: DHCP gave the station an address on the AP's subnet (%s)" % (name, addr))
    if addr:
        tx, rx, avg = traffic(b, addr, 3)
        b.check(rx == tx and tx > 0, "%s: %d/%d echoes over the radio alone, avg %.1f ms" % (name, rx, tx, avg))
    return addr

def main():
    ap_ = args(__doc__.split("\n")[1])
    ap_.add_argument("--no-reboot", action="store_true", help="leave the board on the test AP afterwards")
    a = ap_.parse_args()
    b = Board(a.board, token_file=a.token, serial_log=a.serial_log)
    mark = b.serial_mark()
    try:
        open(CTL, "w").close()
    except OSError as e:
        print("wifi-ap.sh is not running (%s); start it: sudo tests/acceptance/wifi-ap.sh <radio>" % e)
        sys.exit(2)

    st = b.sh("cat /net/ether1/ifstats", wait=1.0)
    b.check("link:" in st, "the station's radio is present (/net/ether1/ifstats)", st.strip()[:100])

    print("== ap_open")
    scenario(b, a, "open")
    print("== ap_wpa2_psk")
    addr = scenario(b, a, "wpa2")
    if addr:
        # throughput over the radio alone: the board sends, the tester reads
        b.kill("Listen")
        b.sh("listen -A 'tcp!*!5002' {sh -c 'load std; while {~ 1 1} {cat /dis/sh.dis}'} &", wait=0.8)
        try:
            s = socket.create_connection((addr, 5002), timeout=10, source_address=("192.168.7.1", 0))
            s.settimeout(5)
            n, end = 0, time.time() + (3 if a.quick else 10)
            while time.time() < end:
                d = s.recv(65536)
                if not d:
                    break
                n += len(d)
            s.close()
            mbps = n * 8 / (3 if a.quick else 10) / 1e6
            b.check(mbps > 2.0, "ap_wpa2_psk: TCP out of the station over the radio: %.1f Mbit/s" % mbps)
        except Exception as e:
            b.check(False, "ap_wpa2_psk: TCP out of the station over the radio", str(e))
        b.kill("Listen")
        # reassociation: the AP goes away and comes back; the supplicant re-joins by itself
        print("== reassociation")
        ap("stop")
        time.sleep(5)
        ap("scenario wpa2")
        t0 = time.time()
        back = False
        while time.time() - t0 < 120:
            tx, rx, avg = traffic(b, addr, 1)
            if rx > 0:
                back = True
                break
            time.sleep(5)
        b.check(back, "reassociation: the station re-joined on its own after the AP came back (%.0fs)" % (time.time() - t0))
    print("== ap_wpa2_psk on 5 GHz")
    scenario(b, a, "wpa2-5g")
    print("== ap_hidden_ssid")
    scenario(b, a, "wpa2-hidden")
    print("== wrong passphrase")
    scenario(b, a, "wpa2", passphrase="not-the-passphrase", expect_join=False, note=" (wrong passphrase)")
    print("== ap_pmf_required")
    scenario(b, a, "wpa2-pmf", note=" (802.11w required; the station must do MFP)")
    print("== sae")
    scenario(b, a, "wpa3", note=" (WPA3-SAE; the station must do SAE)")

    ap("stop")
    text = b.serial_since(mark)
    bad = [l for l in text.splitlines() if re.search(r"panic|unhandled exception|vmachine:|waserror: up is|ether4330: .*(fault|timeout)", l)]
    b.check(not bad, "the kernel said nothing alarming during the run", "; ".join(bad[:3]))
    ok = b.summary()
    if not a.no_reboot:
        print("rebooting the board so it rejoins its own network")
        b.sh("echo reboot > '#c/sysctl'", wait=0.5)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
