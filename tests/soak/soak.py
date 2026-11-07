#!/usr/bin/env python3
"""
One soak for every Raspberry Pi (docs/SOAK.md).

    tests/soak/soak.py --board pi3 --hours 2 [--vmstress] [--flood] [--batteries]
                       [--serial-only] [--loads a,b,...] [--skip a,b,...]

The board is found by name in ~/pitools/boards (MAC -> address through
boardip.py, serial port by its by-path name). It is driven over the network
console when it has one, else over serial; the serial capture (sercap.py) is
read whenever a cable is attached, because a panic is only seen there.

Every load in LOADS declares what it needs. The board and this host are
probed at the start and again every sample; a load whose resource is missing
is SKIPPED with the reason, one whose resource goes away is LOST, and the run
goes on either way. Board-side loops run under one held session, write ticks
and a fail-<n> file per failure in /tmp/soak/<load>/, and stop when
/tmp/soak/run is removed; every failure is fetched to the run directory and
removed from the board, so none is overwritten.

Output: ~/soak/runs/<board>-<start>-<kernel>/ (soak.log, samples.tsv,
memtags/, fails/, summary.txt), and one row in ~/soak/ledger.tsv.
"""
import argparse, fcntl, glob, hashlib, json, os, re, signal, socket, subprocess, sys, threading, time

HOME = os.path.expanduser('~')
PITOOLS = os.path.join(HOME, 'pitools')
SOAKHOME = os.path.join(HOME, 'soak')
CAPTURE = '/mnt/orin-ssd/pdfinn/infernode-captures'
JETSON_IF = 'eno1'
ACCEPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'acceptance')

# ---------------------------------------------------------------- utilities

def now():
    return time.strftime('%Y-%m-%d %H:%M:%S')

def rcq(s):
    """quote for the Inferno shell"""
    return "'" + s.replace("'", "''") + "'"

def jetson_addr():
    out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', JETSON_IF], capture_output=True, text=True).stdout
    m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', out)
    return m.group(1) if m else None

class Log:
    def __init__(self, path):
        self.f = open(path, 'a', buffering=1); self.lk = threading.Lock()
    def __call__(self, s):
        line = '%s %s' % (now(), s)
        with self.lk:
            self.f.write(line + '\n')
        print(line, flush=True)

# ---------------------------------------------------------------- the board

class BoardInfo:
    def __init__(self, name):
        self.name = name; self.mac = self.bdaddr = self.port = None
        for line in open(os.path.join(PITOOLS, 'boards')):
            f = line.split()
            if f and not f[0].startswith('#') and f[0] == name:
                self.mac = f[1].lower()
                self.bdaddr = None if f[2] == '-' else f[2].lower()
                self.port = None if len(f) < 4 or f[3] == '-' else '/dev/serial/by-path/' + f[3]
        if self.mac is None:
            sys.exit('soak: no board %r in ~/pitools/boards' % name)
        env = dict(os.environ, PIBOARD=name)
        self.addr = subprocess.run(['python3', os.path.join(PITOOLS, 'boardip.py')], capture_output=True,
                                   text=True, env=env).stdout.strip() or None
        self.capdir = CAPTURE + '/serial' + ('' if name == 'pi3' else '-' + name)

    def capturing(self):
        """sercap.py running for this board (it owns the serial read side)"""
        for p in glob.glob('/proc/[0-9]*/environ'):
            try:
                env = open(p, 'rb').read().split(b'\0')
                cmd = open(p.replace('environ', 'cmdline'), 'rb').read()
            except OSError:
                continue
            if b'sercap.py' in cmd:
                pb = [e for e in env if e.startswith(b'PIBOARD=')]
                if (pb[0][8:].decode() if pb else 'pi3') == self.name:
                    return True
        return False

    def caplog(self):
        logs = sorted(glob.glob(self.capdir + '/2*.log'))
        return logs[-1] if logs else None


class Console:
    """the network console: one connection per command, held ones for loops"""
    def __init__(self, addr, token):
        self.addr, self.tok = addr, token
        self.c = None; self.lk = threading.Lock(); self.sessions = 0

    def open(self, timeout=15):
        c = socket.create_connection((self.addr, 17010), timeout=timeout)
        c.settimeout(3.0); time.sleep(0.6)
        try:
            c.recv(4096)
        except socket.timeout:
            pass
        c.sendall((self.tok + '\n').encode())
        try:
            c.recv(4096)
        except socket.timeout:
            pass
        return c

    def sh(self, cmds, limit=60):
        """run commands in the one kept session (std loaded); a new session only when it drops.
        Every session is a shell on the board, and with a large live heap the native
        collector may never free one (2026-11-07), so a sampler that opened one a
        minute would grow the heap it measures."""
        with self.lk:
            for attempt in (0, 1):
                try:
                    if self.c is None:
                        self.c = self.open(); self.sessions += 1
                        self._run(self.c, ['load std'], 30)
                    return self._run(self.c, list(cmds), limit)
                except OSError:
                    try:
                        self.c.close()
                    except Exception:
                        pass
                    self.c = None
                    if attempt:
                        raise

    def _run(self, c, cmds, limit):
        out = b''
        if True:
            for cmd in cmds:
                c.sendall((cmd + '; echo @@SOAKEND@@\n').encode())
                t0 = time.time(); buf = b''
                while b'@@SOAKEND@@' not in buf.replace(b'echo @@SOAKEND@@', b'') and time.time() - t0 < limit:
                    try:
                        d = c.recv(65536)
                        if not d:
                            break
                        buf += d
                    except socket.timeout:
                        pass
                if b'@@SOAKEND@@' not in buf.replace(b'echo @@SOAKEND@@', b''):
                    raise OSError('no answer to %r in %d s' % (cmd[:40], limit))
                out += buf.replace(b'echo @@SOAKEND@@', b'').replace(b'@@SOAKEND@@', b'')
        return out.decode(errors='replace').replace('\r', '')

    def put(self, path, data):
        """write a file on the board: cat on its own session, closed for EOF"""
        c = self.open()
        c.sendall(('cat > %s\n' % rcq(path)).encode()); time.sleep(0.5)
        c.sendall(data); time.sleep(0.5)
        c.shutdown(socket.SHUT_WR); time.sleep(1.0); c.close()

    def hold(self, cmd):
        """a session that stays open while cmd runs (closing it ends its loops)"""
        c = self.open()
        c.sendall((cmd + '\n').encode())
        c.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 60)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 15)
        c.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 4)
        return c


class Serial:
    """the serial console: written here, read back from the capture"""
    def __init__(self, info):
        self.info = info
        import serial as _s
        self._serial = _s

    def _type(self, line):
        s = self._serial.Serial(self.info.port, 115200, timeout=0.5)
        for ch in (line + '\r').encode():
            s.write(bytes([ch])); s.flush(); time.sleep(0.01)
        s.close()

    def sh(self, cmds, limit=60):
        out = ''
        for cmd in ['load std'] + list(cmds):
            mark = 'SOAK%d' % int(time.time() * 1000 % 1e9)
            log = self.info.caplog(); off = os.path.getsize(log)
            # the marker is printed by tr, so the echo of the typed line never matches it
            self._type(cmd + '; echo x%s | tr x y' % mark)
            t0 = time.time(); buf = ''
            while time.time() - t0 < limit:
                time.sleep(0.5)
                with open(log, errors='replace') as f:
                    f.seek(off); buf = f.read()
                if 'y' + mark in buf:
                    break
            lines = [l[10:] if re.match(r'\d\d:\d\d:\d\d  ', l) else l for l in buf.splitlines()]
            out += '\n'.join(l for l in lines if mark not in l) + '\n'
        return out

    def put(self, path, data):
        text = data.decode()
        self._type('rm -f %s' % rcq(path))
        for line in text.splitlines():
            self._type('echo %s >> %s' % (rcq(line), rcq(path)))
        time.sleep(1)

    def hold(self, cmd):
        self._type(cmd + ' &')
        return None

# ---------------------------------------------------------------- host locks

class HostRes:
    """advisory locks on the Jetson's shared resources (docs/SOAK.md)"""
    def __init__(self, board, log):
        self.dir = os.path.join(SOAKHOME, 'locks'); os.makedirs(self.dir, exist_ok=True)
        self.board, self.log = board, log; self.waits = {}

    def take(self, name, limit=900):
        f = open(os.path.join(self.dir, name), 'a+')
        t0 = time.time()
        while True:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() - t0 > limit:
                    f.close(); return None
                time.sleep(2)
        waited = time.time() - t0
        if waited > 1:
            self.waits[name] = self.waits.get(name, 0) + waited
            f.seek(0); holder = f.read().strip()
            self.log('host contention: waited %.0f s for %s (last holder: %s)' % (waited, name, holder or '?'))
        f.seek(0); f.truncate(); f.write('%s %s\n' % (self.board, now())); f.flush()
        return f

    def give(self, f):
        if f:
            fcntl.flock(f, fcntl.LOCK_UN); f.close()

# ---------------------------------------------------------------- loads
#
# A load is a dict: name, core (bool), needs (list of resource names),
# board (sh body run in a loop under soakd), host (a function run in a
# thread), what, and an optional pass note. Resources are probed by PROBES.

SOAKD_HEAD = r'''load std
mkdir -p /tmp/soak
fn tick { echo x >> /tmp/soak/$1/ticks }
# A braced block (a backquote's, an if's body) has its own arguments: $1 is
# empty inside one, and "null list in concatenation" kills the whole loop
# (it did, for every load's first failure, 2026-11-07). So the name is taken
# into a variable first.
fn bad {
	name = $1; why = $*
	n = `{ls /tmp/soak/$name | grep fail | wc -l}
	echo $name >> /tmp/soak/bad
	if {! ~ $n 20 21 22 23 24 25} {
		f = /tmp/soak/$name/fail-`{date -n}
		echo $why > $f
		for(o in /tmp/soak/$name/out /tmp/soak/$name/err) { ftest -e $o && { echo '== '^$o >> $f; cat $o >> $f } }
	}
}
fn run { ftest -e /tmp/soak/run }
'''

def L(name, what, board=None, host=None, needs=(), core=False, every=None):
    return dict(name=name, what=what, board=board, host=host, needs=list(needs), core=core, every=every)

# Intensity. Reads are cheap and stay frequent; writes to flash are small,
# verified and budgeted (bytes per day at each profile in the comments).
# --profile sets every area; --stress AREA[,AREA] raises single areas to
# 'stress'. Raw block writes need --scratch DEV=PART: without it no raw
# device is ever written (the Pi 5's NVMe is a store with data on it).
PROFILES = {
    'gentle': dict(sdr_mb=16, sdr_every=600, sdw_kb=0,    sdw_every=0,    nvr_mb=64,  nvr_every=600, nvw_kb=0,     nvw_every=0,
                   net_mb=16, net_every=1800, churn=50,  half=2,  jit_every=900, rsa_every=600, rng_kb=256,   fuzz_every=0),
    'normal': dict(sdr_mb=16, sdr_every=120, sdw_kb=1024, sdw_every=600,  nvr_mb=64,  nvr_every=120, nvw_kb=1024,  nvw_every=300,
                   net_mb=64, net_every=600,  churn=200, half=8,  jit_every=300, rsa_every=60,  rng_kb=4096,  fuzz_every=0),
    'stress': dict(sdr_mb=64, sdr_every=30,  sdw_kb=4096, sdw_every=120,  nvr_mb=256, nvr_every=30,  nvw_kb=16384, nvw_every=60,
                   net_mb=64, net_every=60,   churn=1000, half=32, jit_every=60,  rsa_every=10,  rng_kb=16384, fuzz_every=3600),
}
# SD writes per day: normal 144 MB, stress 2.9 GB; NVMe (scratch only): normal 288 MB, stress 23 GB.
AREAS = {'storage': ('sdr_mb', 'sdr_every', 'sdw_kb', 'sdw_every', 'nvr_mb', 'nvr_every', 'nvw_kb', 'nvw_every'),
         'net': ('net_mb', 'net_every', 'churn', 'half'),
         'cpu': ('jit_every', 'rsa_every', 'rng_kb'),
         'fuzz': ('fuzz_every',),
         'vm': ()}

# Kernel complaints worth a line in the summary (an alarm only for the first group).
ALARMS = r'\b(panic|PANIC|unhandled)\b|exception:|lock loop|miller is a lazy git'
COMPLAINTS = r'out of memory|won.t halt|will not halt|ether0rx|input queue full|arena too large|no free|wedged'

LOADS = [
    # core: every board
    L('fs', 'file churn: copy, ls, write/read/remove on /tmp; /dev/memory reads', core=True, board=r'''
	cat /dis/sh.dis > /tmp/soak/fs/a >[2] /tmp/soak/fs/err || bad fs copy; rm /tmp/soak/fs/a
	ls /dis > /dev/null; ls /tmp > /dev/null
	echo hello > /tmp/soak/fs/b; cat /tmp/soak/fs/b > /tmp/soak/fs/out; ~ `{cat /tmp/soak/fs/out} hello || bad fs readback; rm /tmp/soak/fs/b
	cat /dev/memory > /dev/null
	tick fs'''),
    L('rng', '/dev/random read every minute (profile sets the size); two reads never equal', core=True, board=r'''
	dd -if /dev/random -of /dev/null -bs 65536 -count $rngcount >[2] /tmp/soak/rng/err || bad rng read
	read 32 < /dev/random > /tmp/soak/rng/a; read 32 < /dev/random > /tmp/soak/rng/b
	cmp -s /tmp/soak/rng/a /tmp/soak/rng/b && bad rng duplicate
	tick rng; sleep 60''', needs=['dd']),
    L('rsa', 'auth/rsagen -b 1024 (every minute at normal)', core=True, board=r'''
	auth/rsagen -b 1024 > /tmp/soak/rsa/out >[2] /tmp/soak/rsa/err || bad rsa rsagen
	tick rsa; sleep $rsaevery''', needs=['rsagen']),
    L('jit', 'jitbench, timed (every 5 min at normal)', core=True, board=r'''
	t0 = `{date -n}; jitbench > /tmp/soak/jit/out >[2] /tmp/soak/jit/err || bad jit jitbench
	echo $t0 `{date -n} >> /tmp/soak/jit/times
	tick jit; sleep $jitevery''', needs=['jitbench']),
    L('sd', 'SD card raw reads (16 MB every 2 min at normal); never writes the raw device', core=True, board=r'''
	dd -if $sdraw -of /dev/null -bs 65536 -count $sdrcount >[2] /tmp/soak/sd/err || bad sd read
	tick sd; sleep $sdrevery''', needs=['sdraw', 'dd']),
    L('sd-write', 'a file on the card written, read back, compared and removed (1 MB every 10 min at normal: 144 MB a day)', core=True, board=r'''
	dd -if /dev/random -of /tmp/soak/sd-write/x -bs 1024 -count $sdwkb >[2] /dev/null
	cp /tmp/soak/sd-write/x /n/dos/soak.tmp >[2] /tmp/soak/sd-write/err; cmp /tmp/soak/sd-write/x /n/dos/soak.tmp > /tmp/soak/sd-write/out >[2=1] || bad sd-write verify
	rm -f /n/dos/soak.tmp /tmp/soak/sd-write/x
	tick sd-write; sleep $sdwevery''', needs=['dd', 'budget:sd']),
    L('tls', 'TLS to openssl s_server on the Jetson, verified against the run\'s CA, every 2 min', core=True, board=r'''
	# sh -c, not @{}: @ does not fork the name space, and the bind leaked over the
	# loops' /lib/certs (tls-live then failed against the run's CA alone, 2026-11-07)
	sh -c 'bind /tmp/soak/certs /lib/certs; tlsperf -n 1 https://'^$jetson^':'^$tlsport^'/ > /tmp/soak/tls/out >[2] /tmp/soak/tls/err'
	grep -s 'HTTP 200' /tmp/soak/tls/out || bad tls handshake-or-get
	tick tls; sleep 120''', needs=['tlsperf', 'tlsserver', 'clock', 'console']),
    L('net', '64 MB into the board and 64 MB out, every 10 min; rates logged', core=True,
      host='net', needs=['wired']),
    L('console', 'the serial shell still runs a command, hourly (the 2026-11-07 wedge)', core=True,
      host='console', needs=['serial']),
    # gated
    L('tls-live', 'tls_live_test against example.com and cloudflare.com every 10 min (flagged, not judged)', board=r'''
	/dis/tests/tls_live_test.dis > /tmp/soak/tls-live/out >[2] /tmp/soak/tls-live/err || bad tls-live
	tick tls-live; sleep 600''', needs=['tls_live_test', 'clock', 'internet']),
    L('nvme', 'NVMe raw reads (64 MB every 2 min at normal); never writes', board=r'''
	dd -if '#S/nvme0' -of /dev/null -bs 131072 -count $nvrcount >[2] /tmp/soak/nvme/err || bad nvme read
	tick nvme; sleep $nvrevery''', needs=['nvme', 'dd']),
    L('nvme-write', 'write, read back, compare on the declared scratch partition only (--scratch nvme=PART; 1 MB every 5 min at normal)', board=r'''
	dd -if /dev/random -of /tmp/soak/nvme-write/x -bs 8192 -count $nvwblocks >[2] /dev/null
	dd -if /tmp/soak/nvme-write/x -of $nvscratch -bs 8192 >[2] /tmp/soak/nvme-write/err
	dd -if $nvscratch -of /tmp/soak/nvme-write/y -bs 8192 -count $nvwblocks >>[2] /tmp/soak/nvme-write/err
	cmp /tmp/soak/nvme-write/x /tmp/soak/nvme-write/y > /tmp/soak/nvme-write/out >[2=1] || bad nvme-write verify
	rm -f /tmp/soak/nvme-write/x /tmp/soak/nvme-write/y
	tick nvme-write; sleep $nvwevery''', needs=['nvme', 'dd', 'scratch:nvme', 'budget:nvme']),
    L('spi', 'SPI loopback compare', board=r'''
	read 8192 < /dis/sh.dis > /tmp/soak/spi/s; cat /tmp/soak/spi/s > '#Q/spi0'; cat '#Q/spi0' > /tmp/soak/spi/r
	cmp /tmp/soak/spi/s /tmp/soak/spi/r > /tmp/soak/spi/out >[2=1] || bad spi compare
	tick spi; sleep 1''', needs=['spi']),
    L('i2c', 'I2C reads', board=r'''
	read 1 < '#J/i2c1data' > /dev/null >[2] /tmp/soak/i2c/err || bad i2c read
	tick i2c; sleep 1''', needs=['i2c']),
    L('gpio', 'the loopback jig: drive each pair both ways', board=r'''
	for(p in $gpiopairs) {
		x = `{echo $p | sed 's/:.*//'}; y = `{echo $p | sed 's/.*://'}
		echo 1 > '#G/gpio/'^$x^'/level'; ~ `{cat '#G/gpio/'^$y^'/level'} 1 || bad gpio $x $y high
		echo 0 > '#G/gpio/'^$x^'/level'; ~ `{cat '#G/gpio/'^$y^'/level'} 0 || bad gpio $x $y low
	}
	tick gpio; sleep 1''', needs=['gpiojig']),
    L('bt-scan', 'Bluetooth inquiry and LE scan on the board', board=r'''
	cat /net/bt/scan > /dev/null >[2] /tmp/soak/bt-scan/err || bad bt-scan inquiry
	sleep 20
	ftest -e /net/bt/lescan && { cat /net/bt/lescan > /dev/null >[2] /tmp/soak/bt-scan/err || bad bt-scan lescan }
	tick bt-scan; sleep 20''', needs=['bt']),
    L('bt', 'from the Jetson: l2ping x20 every 10 min (hci0 reserved)', host='bt', needs=['bt', 'bdaddr']),
    L('wifi', '32 MB pushed to the Wi-Fi address every 10 min', host='wifi', needs=['wifi']),
    L('usbnet', '32 MB each way over the USB gadget link every 10 min (gadget reserved)', host='usbnet', needs=['usbnet']),
    L('draw', 'drawbench every 30 s', board=r'''
	sh -c 'bind -a ''#i'' /dev; drawbench > /tmp/soak/draw/out >[2] /tmp/soak/draw/err' || bad draw drawbench
	tick draw; sleep 30''', needs=['drawbench', 'display']),
    L('board', 'RTC, fan, NVMe status reads', board=r'''
	for(f in '#r/rtc' '#P/fanrpm' '#S/nvmestat') { ftest -e $f && { cat $f > /dev/null >[2] /tmp/soak/board/err || bad board $f } }
	tick board; sleep 10''', needs=['boarddevs']),
    L('vm', 'jitbench held in VMs 1 and 2', host='vm', needs=['vm', 'jitbench']),
    L('vmstress', 'vmstress(1) across VMs (--vmstress)', host='vmstress', needs=['vm', 'vmstress', 'opt:vmstress']),
    L('churn', 'TCP connection churn: connects and closes, and half-open connections held 60 s (200 and 8 every 10 min at normal); the board conversations must come back', core=True,
      host='churn', needs=['wired']),
    L('latency', 'ping the wired address every minute: average and maximum round trip', core=True, host='latency', needs=['wired']),
    L('fuzz', 'sysfuzz for 10 min an hour, scratch in /tmp (no flash writes) (--stress fuzz)', board=r'''
	/dis/tests/sysfuzz.dis -s `{date -n} -t 600 -e 5 -p 6 -d /tmp/soak/fuzz/scratch > /tmp/soak/fuzz/out >[2] /tmp/soak/fuzz/err
	grep -s 'sysfuzz: done' /tmp/soak/fuzz/out || bad fuzz not-done
	rm -rf /tmp/soak/fuzz/scratch; mkdir -p /tmp/soak/fuzz/scratch
	tick fuzz; sleep $fuzzevery''', needs=['sysfuzz', 'opt:fuzz']),
    L('flood', 'console flood: 80-column lines to #c/cons as fast as the UART takes them (--flood)', host='flood',
      needs=['console', 'opt:flood']),
]

# ---------------------------------------------------------------- the run

class Run:
    def __init__(self, a):
        self.a = a
        self.info = BoardInfo(a.board)
        self.tok = open(os.path.join(PITOOLS, 'netcons.token')).read().strip()
        self.jetson = jetson_addr()
        self.t0 = time.time()
        self.stop = threading.Event()
        self.res = {}           # resource -> (bool, why)
        self.state = {}         # load -> 'run' | 'skip: why' | 'lost at ...: why'
        self.hostfail = {}      # load -> count
        self.hostpass = {}
        self.rates = {}
        self.kernel = None
        self.gpiopairs = None
        # One TLS server for every run, on 8443: the Jetson's firewall lets the LAN
        # reach 8443 and refused 8444 and 8460 (2026-11-07), so per-board ports fail.
        self.tlsport = 8443
        self.lat = []
        self.churnres = []
        # intensity: the profile, raised to 'stress' in the areas named
        self.iv = dict(PROFILES[a.profile])
        for area in a.stress:
            if area not in AREAS:
                sys.exit('soak: no stress area %r (have %s)' % (area, ', '.join(AREAS)))
            for k in AREAS[area]:
                self.iv[k] = PROFILES['stress'][k]
        self.scratch = dict(x.split('=', 1) for x in a.scratch)

    # transport ----------------------------------------------------------
    def connect(self):
        self.cons = None; self.ser = None
        if self.info.port and os.path.exists(self.info.port) and self.info.capturing():
            self.ser = Serial(self.info)
        if self.info.addr and not self.a.serial_only:
            try:
                Console(self.info.addr, self.tok).sh(['echo ok'], 15)
                self.cons = Console(self.info.addr, self.tok)
            except OSError:
                pass
        self.drv = self.cons or self.ser
        if self.drv is None:
            sys.exit('soak: %s has neither a network console nor a captured serial line' % self.info.name)

    def sh(self, *cmds, limit=60):
        return self.drv.sh(cmds, limit)

    # probes -------------------------------------------------------------
    def probe(self):
        r = {}
        r['console'] = (self.cons is not None, 'network console' if self.cons else 'no network console (serial only)')
        r['serial'] = (self.ser is not None, 'captured serial line' if self.ser else
                       ('no serial cable in ~/pitools/boards' if not self.info.port else 'serial not captured (start sercap.py)'))
        out = self.sh(
            "for(f in jitbench drawbench memtouch auth/rsagen vm zeros tlsperf vmstress tests/tls_live_test tests/sysfuzz dd cmp) { ftest -e /dis/$f.dis && echo HAVE $f }",
            "for(f in '#S/sdcard' '#S/sd0' '#S/nvme0' '#Q/spi0' '#J/i2c1data' '#r/rtc' '#P/fanrpm' '#P/cputemp' '#S/nvmestat' /dev/memtags /dev/heapaudit /net/bt/status '#i/draw') { ftest -e $f && echo DEV $f }",
            "ls '#X' >[2] /dev/null > /dev/null && echo DEV vm",
            "cat /net/bt/status >[2] /dev/null | sed 1q",
            "cat /net/ipifc/*/status | grep '^device|^	[0-9]'",
            "echo BOARDTIME `{date -n}",
            limit=60)
        have = set(re.findall(r'HAVE (\S+)', out)); dev = set(re.findall(r'DEV (\S+)', out))
        def tool(n):
            return (n in have, '/dis/%s.dis' % n + ('' if n in have else ' missing'))
        for n in ('jitbench', 'drawbench', 'memtouch', 'vmstress', 'tlsperf', 'dd'):
            r[n] = tool(n)
        r['rsagen'] = tool('auth/rsagen')
        r['tls_live_test'] = tool('tests/tls_live_test')
        r['sysfuzz'] = tool('tests/sysfuzz')
        r['budget:sd'] = (self.iv['sdw_kb'] > 0, 'profile %s writes no files to the card' % self.a.profile)
        r['budget:nvme'] = (self.iv['nvw_kb'] > 0, 'profile %s writes nothing to NVMe' % self.a.profile)
        r['scratch:nvme'] = ('nvme' in self.scratch, 'no --scratch nvme=PART (NVMe is never written without one)')
        sd = [d for d in ("'#S/sdcard'", "'#S/sd0'") if d.strip("'") in dev]
        r['sdraw'] = (bool(sd), sd[0].strip("'") if sd else 'no raw SD device (#S/sdcard, #S/sd0)')
        self.sdraw = sd[0] if sd else None
        for k, d in (('nvme', '#S/nvme0'), ('spi', '#Q/spi0'), ('i2c', '#J/i2c1data')):
            r[k] = (d in dev, d + ('' if d in dev else ' missing'))
        r['boarddevs'] = (any(d in dev for d in ('#r/rtc', '#P/fanrpm', '#S/nvmestat')), 'RTC/fan/nvmestat')
        r['memtags'] = ('/dev/memtags' in dev, '/dev/memtags')
        r['heapaudit'] = ('/dev/heapaudit' in dev, '/dev/heapaudit')
        r['cputemp'] = ('#P/cputemp' in dev, '#P/cputemp')
        r['display'] = ('#i/draw' in dev, '#i/draw (a display)')
        r['vm'] = ('vm' in dev and 'vm' in have, '#X and /dis/vm.dis')
        r['bt'] = ('up 1' in out, '/net/bt up' if 'up 1' in out else '/net/bt not up (no /n/dos/bt?)')
        r['bdaddr'] = (self.info.bdaddr is not None, 'Bluetooth address in ~/pitools/boards')
        addrs = re.findall(r'^\t(\d+\.\d+\.\d+\.\d+) ', out, re.M)
        devs = re.findall(r'^device (\S+)', out, re.M)
        ifs = list(zip(devs, addrs))
        self.wired = self.info.addr
        self.usbaddr = next((a for d, a in ifs if a.startswith('192.168.57.')), None)
        self.wifiaddr = next((a for d, a in ifs if a != self.info.addr and not a.startswith(('192.168.57.', '127.'))
                              and 'loopback' not in d and d != '/net/ether0'), None)
        r['wired'] = (self.info.addr in addrs if self.info.addr else False, 'wired address %s' % self.info.addr)
        r['usbnet'] = (self.usbaddr is not None, 'gadget link %s' % (self.usbaddr or 'down'))
        r['wifi'] = (self.wifiaddr is not None, 'Wi-Fi %s' % (self.wifiaddr or 'not associated'))
        m = re.search(r'BOARDTIME (\d+)', out)
        bt = int(m.group(1)) if m else 0
        r['clock'] = (abs(bt - time.time()) < 300, 'board clock %s' % (time.strftime('%Y-%m-%d %H:%M', time.gmtime(bt)) if m else '?'))
        r['internet'] = (subprocess.run(['ping', '-c1', '-W2', '1.1.1.1'], capture_output=True).returncode == 0, 'Jetson reaches 1.1.1.1')
        r['tlsserver'] = (getattr(self, 'tlsup', False) and ':%d ' % self.tlsport in subprocess.run(['ss', '-ltn'], capture_output=True, text=True).stdout,
                          'openssl s_server on %s:%d' % (self.jetson, self.tlsport))
        r['gpiojig'] = (getattr(self, 'gpiopairs', None) is not None, 'loopback jig fitted' if getattr(self, 'gpiopairs', None) else 'no loopback jig')
        r['opt:vmstress'] = (self.a.vmstress or 'vm' in self.a.stress, '--vmstress or --stress vm')
        r['opt:fuzz'] = (self.iv['fuzz_every'] > 0, '--stress fuzz or --profile stress')
        r['opt:flood'] = (self.a.flood, '--flood')
        return r

    def options(self):
        a = self.a
        return 'hours=%g profile=%s stress=%s vmstress=%s flood=%s batteries=%s scratch=%s' % (
            a.hours, a.profile, ','.join(a.stress) or '-', a.vmstress, a.flood, a.batteries,
            ','.join(a.scratch) or '-')

    def gate(self, load, r):
        miss = [n for n in load['needs'] if not r.get(n, (False, n + ' unknown'))[0]]
        return miss

    # board preparation ---------------------------------------------------
    def setclock(self):
        self.sh('echo %d > /dev/time' % int(time.time() * 1e6))

    def probejig(self):
        pairs = [(4, 17), (27, 22), (5, 6), (13, 19)]
        cmds = []
        for x, y in pairs:
            cmds.append("echo function out > '#G/gpio/%d/ctl' >[2] /dev/null; echo function in > '#G/gpio/%d/ctl' >[2] /dev/null; "
                        "echo 1 > '#G/gpio/%d/level' >[2] /dev/null; echo P%d:%d `{cat '#G/gpio/%d/level' >[2] /dev/null}; "
                        "echo 0 > '#G/gpio/%d/level' >[2] /dev/null; echo Q%d:%d `{cat '#G/gpio/%d/level' >[2] /dev/null}" % (x, y, x, x, y, y, x, x, y, y))
        out = self.sh(*cmds)
        fitted = [(x, y) for x, y in pairs if re.search(r'P%d:%d 1\b' % (x, y), out) and re.search(r'Q%d:%d 0\b' % (x, y), out)]
        self.gpiopairs = fitted or None

    def tlsserver(self):
        """the shared test server: ~/soak/tls holds one CA and one server certificate
        (made once, valid 10 years); the server is started if nothing listens on the
        port, detached so that it outlives this run and serves the others"""
        d = os.path.join(SOAKHOME, 'tls'); os.makedirs(d, exist_ok=True)
        def o(*args):
            subprocess.run(['openssl'] + list(args), cwd=d, capture_output=True, check=True)
        if not os.path.exists(os.path.join(d, 'ca.der')):
            open(os.path.join(d, 'san.ext'), 'w').write('subjectAltName=IP:%s\n' % self.jetson)
            o('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '3650', '-subj', '/CN=SoakCA')
            o('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'srv.key')
            o('req', '-new', '-key', 'srv.key', '-subj', '/CN=%s' % self.jetson, '-out', 'srv.csr')
            o('x509', '-req', '-in', 'srv.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-days', '3650', '-extfile', 'san.ext', '-out', 'srv.pem')
            o('x509', '-in', 'ca.pem', '-outform', 'der', '-out', 'ca.der')
        listening = ':%d ' % self.tlsport in subprocess.run(['ss', '-ltn'], capture_output=True, text=True).stdout
        if not listening:
            subprocess.Popen(['setsid', 'openssl', 's_server', '-accept', str(self.tlsport), '-cert', 'srv.pem', '-key', 'srv.key', '-www', '-quiet'],
                             cwd=d, stdout=open(os.path.join(d, 's_server.log'), 'a'), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
            time.sleep(1)
            self.log('TLS server started on %s:%d (shared; it stays up for other runs)' % (self.jetson, self.tlsport))
        else:
            self.log('TLS server already up on :%d (shared)' % self.tlsport)
        self.tlsup = True
        if self.cons:
            self.cons.sh(['mkdir -p /tmp/soak/certs'])
            self.cons.put('/tmp/soak/certs/ca.der', open(os.path.join(d, 'ca.der'), 'rb').read())

    def soakd(self, loads):
        body = self.soakd_text(loads)
        self.drv.put('/tmp/soak/soakd.sh', body.encode())
        return body

    def soakd_text(self, loads):
        body = SOAKD_HEAD
        body += 'sdraw = %s\njetson = %s\ntlsport = %d\n' % (self.sdraw or "''", self.jetson, self.tlsport)
        iv = self.iv
        body += ('sdrcount = %d\nsdrevery = %d\nsdwkb = %d\nsdwevery = %d\nnvrcount = %d\nnvrevery = %d\n'
                 'nvwblocks = %d\nnvwevery = %d\nnvscratch = %s\njitevery = %d\nrsaevery = %d\nrngcount = %d\nfuzzevery = %d\n') % (
            iv['sdr_mb'] * 16, iv['sdr_every'], iv['sdw_kb'], max(iv['sdw_every'], 1), iv['nvr_mb'] * 8, iv['nvr_every'],
            iv['nvw_kb'] // 8, max(iv['nvw_every'], 1), rcq(self.scratch.get('nvme', '/dev/null')), iv['jit_every'],
            iv['rsa_every'], max(iv['rng_kb'] // 64, 1), max(iv['fuzz_every'] - 600, 60))
        body += 'gpiopairs = (%s)\n' % ' '.join('%d:%d' % p for p in (self.gpiopairs or []))
        for l in loads:
            body += 'mkdir -p /tmp/soak/%s\n' % l['name']
        body += 'mkdir -p /tmp/soak/fuzz/scratch\n'
        body += 'echo > /tmp/soak/run\n'
        for l in loads:
            body += '{ while {run} {%s\n} } &\n' % l['board']
        # the host loads' listeners, held by this session too
        body += "listen -A 'tcp!*!8702' {cat > /dev/null} &\n"
        body += "listen -A 'tcp!*!8703' {zeros 65536 1024} &\n"
        body += 'echo soakd-up\n'
        body += 'while {run} {sleep 30}\n'
        return body

    # host loads ----------------------------------------------------------
    def every(self, secs, fn, name, first=30):
        def loop():
            if self.stop.wait(first):
                return
            while not self.stop.is_set():
                if self.state.get(name, '').startswith('run'):
                    try:
                        ok, note = fn()
                    except Exception as e:
                        ok, note = False, 'exception: %s' % e
                    if ok:
                        self.hostpass[name] = self.hostpass.get(name, 0) + 1
                    else:
                        self.hostfail[name] = self.hostfail.get(name, 0) + 1
                        self.fail(name, note)
                    if note:
                        self.log('%s: %s' % (name, note))
                if self.stop.wait(secs):
                    return
        threading.Thread(target=loop, daemon=True).start()

    def push(self, addr, mb, name):
        lk = self.hres.take('jetson-nic')
        try:
            c = socket.create_connection((addr, 8702), timeout=15); data = b'\xa5' * (1 << 20); t0 = time.time()
            for _ in range(mb):
                c.sendall(data)
            c.shutdown(socket.SHUT_WR)
            try:
                c.settimeout(60); c.recv(1)
            except Exception:
                pass
            c.close(); rin = mb * 8 / (time.time() - t0)
            c = socket.create_connection((addr, 8703), timeout=15); c.settimeout(60); n = 0; t0 = time.time()
            while True:
                b = c.recv(1 << 20)
                if not b:
                    break
                n += len(b)
            c.close(); rout = n * 8 / (time.time() - t0) / 1e6
        finally:
            self.hres.give(lk)
        self.rates.setdefault(name, []).append((rin, rout))
        return True, 'in %d MB at %.1f Mbit/s, out %d MB at %.1f Mbit/s' % (mb, rin, n >> 20, rout)

    def h_net(self):
        return self.push(self.info.addr, self.iv['net_mb'], 'net')

    def tcpconvs(self):
        # open conversations: /net/tcp lists every one ever allocated, Closed ones included
        out = self.sh("cat /net/tcp/[0-9]*/status >[2] /dev/null | grep -v '^Closed' | wc -l", limit=30)
        m = re.search(r'(\d+)', out)
        return int(m.group(1)) if m else -1

    def h_churn(self):
        before = self.tcpconvs()
        n = self.iv['churn']; bad = 0
        for i in range(n):
            try:
                c = socket.create_connection((self.info.addr, 8702), timeout=5); c.sendall(b'x'); c.close()
            except OSError:
                bad += 1
        half = []
        for i in range(self.iv['half']):
            try:
                half.append(socket.create_connection((self.info.addr, 8702), timeout=5))
            except OSError:
                bad += 1
        self.stop.wait(60)
        for c in half:
            try:
                c.close()
            except OSError:
                pass
        self.stop.wait(90)
        after = self.tcpconvs()
        self.churnres.append((before, after, bad))
        grew = after - before
        ok = bad == 0 and grew <= 4
        return ok, '%d connects, %d half-open held 60 s, %d refused; board conversations %d -> %d' % (n, len(half), bad, before, after)

    def h_latency(self):
        r = subprocess.run(['ping', '-q', '-c', '5', '-i', '0.2', '-W', '2', self.info.addr], capture_output=True, text=True)
        m = re.search(r'= [\d.]+/([\d.]+)/([\d.]+)', r.stdout); l = re.search(r'(\d+)% packet loss', r.stdout)
        if m:
            self.lat.append((float(m.group(1)), float(m.group(2)), int(l.group(1)) if l else 0))
        return (m is not None and (not l or l.group(1) != '100')), ''

    def h_wifi(self):
        return self.push(self.wifiaddr, 32, 'wifi')

    def h_usbnet(self):
        lk = self.hres.take('usb-gadget')
        try:
            return self.push(self.usbaddr, 32, 'usbnet')
        finally:
            self.hres.give(lk)

    def h_bt(self):
        lk = self.hres.take('hci0')
        try:
            r = subprocess.run(['l2ping', '-i', 'hci0', '-c', '20', '-t', '5', self.info.bdaddr], capture_output=True, text=True, timeout=180)
        finally:
            self.hres.give(lk)
        m = re.search(r'(\d+) sent, (\d+) received', r.stdout + r.stderr)
        ok = bool(m) and m.group(1) == m.group(2)
        return ok, 'l2ping %s' % (('%s/%s answered' % (m.group(2), m.group(1))) if m else (r.stdout + r.stderr).strip()[-80:])

    def h_console(self):
        mark = 'chk%d' % int(time.time())
        log = self.info.caplog(); off = os.path.getsize(log)
        Serial(self.info)._type('echo x-%s | tr x y' % mark)
        # a line idle for an hour can take several seconds to answer (5 s was too short)
        t0 = time.time(); got = ''
        while time.time() - t0 < 30 and 'y-' + mark not in got:
            time.sleep(2)
            with open(log, errors='replace') as f:
                f.seek(off); got = f.read()
        full = len(re.findall(r'kbd: input queue full', got))
        return ('y-' + mark in got), ('serial shell runs commands' if 'y-' + mark in got else 'SERIAL SHELL DOES NOT RUN COMMANDS') + (' (input queue full x%d)' % full if full else '')

    def holdhost(self, name, cmd):
        """a board command held on its own console session for the run"""
        def keep():
            while not self.stop.is_set():
                try:
                    c = self.cons.hold('load std; ' + cmd)
                    self.log('%s: held' % name)
                    c.settimeout(60)
                    # what the session prints (a loop's shell error among it) is kept
                    held = open(os.path.join(self.dir, 'held-%s.txt' % name), 'ab', 0)
                    while not self.stop.is_set():
                        try:
                            b = c.recv(65536)
                            if not b:
                                break
                            held.write(b)
                        except socket.timeout:
                            pass
                except OSError:
                    pass
                if not self.stop.is_set():
                    self.log('%s: session down; again in 60 s' % name); self.stop.wait(60)
        threading.Thread(target=keep, daemon=True).start()

    # samplers -----------------------------------------------------------
    def sample(self, n):
        out = self.sh('cat /dev/memory', 'ftest -e /tmp/soak/run && echo RUNNING',
                      "echo PROCS `{ls /prog | wc -l}; echo TCPCONV `{cat /net/tcp/[0-9]*/status >[2] /dev/null | grep -v '^Closed' | wc -l}; echo BOARDTIME `{date -n}",
                      "ls -l /dev/bootimage", "cat '#P/cputemp' '#P/throttled' >[2] /dev/null",
                      'wc -l /tmp/soak/*/ticks >[2] /dev/null', 'ls /tmp/soak/*/fail-* >[2] /dev/null', limit=60)
        pools = {m.group(7): (int(m.group(1)), int(m.group(3))) for m in
                 re.finditer(r'^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+(main|heap|image)\s*$', out, re.M)}
        ticks = {m.group(2): int(m.group(1)) for m in re.finditer(r'(\d+) /tmp/soak/([\w-]+)/ticks', out)}
        size = re.search(r' (\d+) [A-Z][a-z][a-z] .*bootimage', out)
        temp = re.findall(r'^(\d+\.\d+)', out, re.M)
        running = 'RUNNING' in out
        g = lambda k: (re.search(k + r' (\d+)', out) or [None, ''])[1]
        bt = g('BOARDTIME'); drift = '%d' % (int(bt) - int(time.time())) if bt else ''
        lat = self.lat[-1] if self.lat else ('', '', '')
        self.samples.write('%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' % (
            now(), int(time.time() - self.t0),
            pools.get('main', ('', ''))[0], pools.get('heap', ('', ''))[0], pools.get('image', ('', ''))[0],
            size.group(1) if size else '', temp[0] if temp else '', json.dumps(ticks),
            g('PROCS'), g('TCPCONV'), drift, lat[0], lat[1]))
        self.samples.flush()
        fails = re.findall(r'(/tmp/soak/[\w-]+/fail-\d+)', out)
        for f in fails:
            body = self.sh('cat %s' % f, 'rm %s' % f)
            name = f.split('/')[3]
            self.fail(name, body.strip()[-2000:])
        return pools, size.group(1) if size else None, running, ticks

    def memtags(self, tag):
        if not self.res.get('memtags', (False,))[0]:
            return
        out = self.sh('cat /dev/memtags', limit=90)
        open(os.path.join(self.dir, 'memtags', '%s.txt' % tag), 'w').write(out)

    def fail(self, name, text):
        d = os.path.join(self.dir, 'fails'); os.makedirs(d, exist_ok=True)
        n = len(glob.glob(os.path.join(d, name + '-*')))
        open(os.path.join(d, '%s-%03d.txt' % (name, n)), 'w').write('%s\n%s\n' % (now(), text))
        self.failcount[name] = self.failcount.get(name, 0) + 1

    def serialscan(self):
        """alarm lines (panics) and complaints on the serial capture since the start"""
        if not self.ser:
            return []
        bad = []; self.complaints = {}
        t0 = time.strftime('%H:%M:%S', time.localtime(self.t0)); d0 = time.strftime('%Y-%m-%d', time.localtime(self.t0))
        for log in sorted(glob.glob(self.info.capdir + '/2*.log')):
            if os.path.basename(log)[:10] < d0:
                continue
            first = os.path.basename(log)[:10] == d0
            for l in open(log, errors='replace'):
                if first and l[:8] < t0:
                    continue
                if 'soak flood' in l:
                    continue
                if re.search(ALARMS, l) and 'exception path' not in l:
                    bad.append(l.strip())
                m = re.search(COMPLAINTS, l)
                if m:
                    self.complaints[m.group(0)] = self.complaints.get(m.group(0), 0) + 1
        return bad

    # batteries ------------------------------------------------------------
    def batteries(self, when):
        for bat, args in (('ethernet', ['--frag-via', 'minipc']), ('bluetooth', ['--bdaddr', self.info.bdaddr or '']), ('gpio', [])):
            if bat == 'bluetooth' and not (self.res['bt'][0] and self.info.bdaddr):
                self.log('battery %s %s: skipped (%s)' % (bat, when, self.res['bt'][1])); continue
            out = os.path.join(self.dir, 'battery-%s-%s.txt' % (bat, when))
            lk = self.hres.take('hci0') if bat == 'bluetooth' else None
            try:
                # 10 min each: the GPIO battery hung to its limit on the Pi 4 (2026-11-07,
                # edge events never reported), and a hung battery should not eat the run
                rc = subprocess.call(['python3', '-u', os.path.join(ACCEPT, bat + '.py'), '--board', self.info.addr] + args,
                                     stdout=open(out, 'w'), stderr=subprocess.STDOUT, timeout=600 if bat == 'gpio' else 1200)
            except subprocess.TimeoutExpired:
                rc = -1
            finally:
                self.hres.give(lk)
            summ = [l.strip() for l in open(out) if l.startswith('Passed')]
            self.batt[(bat, when)] = summ[0] if summ else 'rc=%d' % rc
            self.log('battery %s %s: %s' % (bat, when, self.batt[(bat, when)]))

    # main ------------------------------------------------------------------
    def main(self):
        a = self.a
        self.connect()
        out = self.sh('ls -l /dev/bootimage', 'sha1sum /dev/bootimage', limit=90)
        m = re.search(r'([0-9a-f]{40})', out); s = re.search(r' (\d+) [A-Z][a-z][a-z] .*bootimage', out)
        self.kernel = (s.group(1) if s else '?', m.group(1) if m else '?')
        stamp = time.strftime('%Y%m%d-%H%M')
        self.dir = os.path.join(SOAKHOME, 'runs', '%s-%s-%s' % (self.info.name, stamp, self.kernel[1][:8]))
        os.makedirs(os.path.join(self.dir, 'memtags'), exist_ok=True)
        self.log = Log(os.path.join(self.dir, 'soak.log'))
        self.samples = open(os.path.join(self.dir, 'samples.tsv'), 'a')
        self.samples.write('time\tsecs\tmain\theap\timage\tbootimage\ttemp\tticks\tprocs\ttcpconv\tclockdrift\trtt_avg\trtt_max\n')
        self.hres = HostRes(self.info.name, self.log)
        self.failcount = {}; self.batt = {}
        self.log('soak %s: kernel %s bytes sha1 %s; driven over %s; serial %s; options: %s' % (
            self.info.name, self.kernel[0], self.kernel[1], 'network console' if self.cons else 'serial',
            'captured' if self.ser else 'none', self.options()))
        self.log('intensity: ' + ' '.join('%s=%s' % kv for kv in sorted(self.iv.items())))
        if a.card:
            r = subprocess.run(['python3', os.path.join(ACCEPT, 'card.py'), '--board', self.info.addr,
                                '--root', os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')],
                               capture_output=True, text=True, timeout=1800)
            open(os.path.join(self.dir, 'card.txt'), 'w').write(r.stdout + r.stderr)
            summ = [l for l in (r.stdout).splitlines() if l.startswith('Passed')]
            self.log('card against this tree: %s' % (summ[0] if summ else 'rc=%d' % r.returncode))
        if a.dry:
            r = self.res = self.probe()
            sel = [l for l in LOADS if (not a.loads or l['name'] in a.loads) and l['name'] not in a.skip]
            for l in sel:
                miss = self.gate(l, r)
                self.log('load %-10s %s%s' % (l['name'], 'RUN ' if not miss else 'SKIP',
                         '' if not miss else '  (' + '; '.join(r.get(n, (0, n))[1] for n in miss) + ')'))
            self.log('dry run: nothing was changed on the board (no clock set, no jig driven, no TLS server, no loops)')
            print(self.soakd_text([l for l in sel if l['board'] and not self.gate(l, r)]))
            return
        # leftovers of an earlier run
        self.sh('rm -f /tmp/soak/run', limit=20); time.sleep(35)
        self.sh('rm -rf /tmp/soak', 'mkdir -p /tmp/soak', limit=30)
        r = self.probe()
        if not r['clock'][0]:
            self.setclock(); self.log('board clock was %s; set from the Jetson' % r['clock'][1])
        self.probejig()
        try:
            self.tlsserver()
        except Exception as e:
            self.log('TLS server not started: %s' % e)
        self.res = r = self.probe()
        open(os.path.join(self.dir, 'resources.json'), 'w').write(json.dumps(r, indent=1))
        sel = [l for l in LOADS if (not a.loads or l['name'] in a.loads) and l['name'] not in a.skip]
        for l in sel:
            miss = self.gate(l, r)
            self.state[l['name']] = 'run' if not miss else 'skip: ' + '; '.join(r.get(n, (0, n))[1] for n in miss)
            self.log('load %-9s %s%s' % (l['name'], 'RUN ' if not miss else 'SKIP', '' if not miss else '  (' + self.state[l['name']][6:] + ')'))
        if self.stop.is_set():
            self.log('stopped during setup (SIGTERM)'); return
        if a.batteries:
            self.batteries('before')
        if self.stop.is_set():
            self.log('stopped during setup (SIGTERM)'); return
        self.memtags('start')
        # the board loops, held by one session
        board = [l for l in sel if l['board'] and self.state[l['name']] == 'run']
        self.soakd(board)
        if self.cons:
            self.holdhost('soakd', 'sh /tmp/soak/soakd.sh')
        else:
            self.drv.hold('sh /tmp/soak/soakd.sh')
        time.sleep(20)
        # host loads
        st = lambda n: self.state.get(n, '') == 'run'
        if st('net'): self.every(self.iv['net_every'], self.h_net, 'net', first=60)
        if st('churn'): self.every(600, self.h_churn, 'churn', first=240)
        if st('latency'): self.every(60, self.h_latency, 'latency', first=20)
        if st('wifi'): self.every(600, self.h_wifi, 'wifi', first=180)
        if st('usbnet'): self.every(600, self.h_usbnet, 'usbnet', first=300)
        if st('bt'): self.every(600, self.h_bt, 'bt', first=420)
        if st('console'): self.every(3600, self.h_console, 'console', first=600)
        if st('vm'): self.holdhost('vm', "vm 1 sh -c 'load std; while {ftest -e /tmp/soak/run} {jitbench > /dev/null}'; vm 2 sh -c 'load std; while {ftest -e /tmp/soak/run} {jitbench > /dev/null}'; while {ftest -e /tmp/soak/run} {sleep 30}")
        if st('vmstress'): self.holdhost('vmstress', 'vmstress /tmp/soak/vs')
        if st('flood'):
            def flood():
                while not self.stop.is_set():
                    try:
                        c = self.cons.open(); c.sendall(b"cat > '#c/cons'\n"); c.settimeout(None); i = 0
                        while not self.stop.is_set():
                            c.sendall(''.join(('soak flood %08d ' % (i + k)).ljust(79, 'x') + '\n' for k in range(50)).encode()); i += 50
                        c.close()
                    except OSError:
                        self.stop.wait(30)
            threading.Thread(target=flood, daemon=True).start()
        # the watch
        end = self.t0 + a.hours * 3600; n = 0; miss = 0; nexttags = time.time() + 3600; alarm = None
        first = None
        while time.time() < end and not alarm and not self.stop.is_set():
            self.stop.wait(60); n += 1
            try:
                pools, size, running, ticks = self.sample(n); miss = 0
                if first is None:
                    first = pools
                if size and size != self.kernel[0]:
                    alarm = 'the running kernel changed size (%s, was %s): a reboot fell back' % (size, self.kernel[0])
                elif not running:
                    alarm = '/tmp/soak/run is gone: the board rebooted or the loops were stopped'
            except Exception as e:
                miss += 1; self.log('sample failed (%d in a row): %s' % (miss, e))
                if miss >= 3:
                    alarm = 'the board has not answered three samples'
            bad = self.serialscan()
            if bad:
                alarm = 'serial: ' + bad[0]
            if time.time() >= nexttags:
                self.memtags(time.strftime('%H%M')); nexttags += 3600
                self.res = rr = self.probe()
                for l in sel:
                    if self.state[l['name']] == 'run':
                        miss2 = self.gate(l, rr)
                        if miss2:
                            self.state[l['name']] = 'lost at %s: %s' % (now(), '; '.join(rr[x][1] for x in miss2))
                            self.log('load %s LOST: %s' % (l['name'], self.state[l['name']]))
            if n % 15 == 0:
                self.log('t=%dm main %s heap %s; ticks %s; failures %s' % (
                    (time.time() - self.t0) / 60, pools.get('main', ('?',))[0] if not miss else '?',
                    pools.get('heap', ('?',))[0] if not miss else '?', ticks if not miss else '?', self.failcount))
        if alarm:
            self.log('ALARM: ' + alarm)
        elif self.stop.is_set():
            self.log('stopped early (SIGTERM)')
        # the end (stopped early: no batteries after, so a SIGTERM ends it quickly)
        early = self.stop.is_set()
        self.stop.set()
        try:
            self.sh('rm -f /tmp/soak/run', limit=20)
        except Exception:
            pass
        time.sleep(40)
        try:
            self.sample(n + 1)
        except Exception:
            pass
        self.memtags('end')
        if a.batteries and not alarm and not early:
            self.batteries('after')
        self.summary(alarm, sel)

    # summary -----------------------------------------------------------------
    def summary(self, alarm, sel):
        rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(self.dir, 'samples.tsv'))][1:]
        def series(col):
            return [(int(r[1]), int(r[col])) for r in rows if len(r) > col and r[col].isdigit()]
        def floor(s, at, w=6):
            vals = [v for t, v in s if abs(t - at) <= w * 60]
            return min(vals) if vals else None
        out = []
        out.append('soak %s %s' % (self.info.name, os.path.basename(self.dir)))
        out.append('kernel %s bytes, sha1 %s; driven over %s; %s' % (self.kernel[0], self.kernel[1],
                   'network console' if self.cons else 'serial', 'ALARM: ' + alarm if alarm else 'no alarm'))
        out.append('options: %s; length %.1f h' % (self.options(), (time.time() - self.t0) / 3600))
        if self.cons:
            out.append('console sessions opened by this run: %d (one kept for commands, plus one per held load and upload)' % self.cons.sessions)
        if self.hres.waits:
            out.append('host contention: ' + ', '.join('%s %.0f s' % kv for kv in self.hres.waits.items()))
        out.append('')
        out.append('%-10s %-6s %8s %8s  %s' % ('load', 'state', 'passes', 'fails', 'note'))
        last = rows[-1] if rows else None
        ticks = json.loads(last[7]) if last and len(last) > 7 and last[7] else {}
        for l in sel:
            s = self.state.get(l['name'], '?'); kind = s.split(':')[0].split(' ')[0]
            passes = ticks.get(l['name'], self.hostpass.get(l['name'], 'held' if l['name'] in ('vm', 'vmstress', 'flood') else 0))
            out.append('%-10s %-6s %8s %8s  %s' % (l['name'], kind, passes if kind == 'run' or kind == 'lost' else '-',
                       self.failcount.get(l['name'], 0) if kind != 'skip' else '-', s[len(kind):].lstrip(': ') or l['what']))
        out.append('')
        for col, name in ((2, 'main'), (3, 'heap'), (4, 'image')):
            s = series(col)
            if len(s) > 12:
                a, b = floor(s, s[min(10, len(s) - 1)][0]), floor(s, s[-1][0])
                hrs = max((s[-1][0] - s[min(10, len(s) - 1)][0]) / 3600, 0.01)
                out.append('%-5s floor %d -> %d bytes, %+.0f bytes/h' % (name, a, b, (b - a) / hrs))
        wt = ticks.get('sd-write', 0) * self.iv['sdw_kb'] * 1024; nt = ticks.get('nvme-write', 0) * self.iv['nvw_kb'] * 1024
        out.append('written: SD %.1f MB (files), NVMe %.1f MB (%s); raw SD never' % (
            wt / 1e6, nt / 1e6, self.scratch.get('nvme', 'no scratch: never')))
        if self.lat:
            avgs = sorted(x[0] for x in self.lat); mx = max(x[1] for x in self.lat)
            out.append('latency  %d samples; median avg %.2f ms, worst max %.2f ms, samples with loss %d' % (
                len(self.lat), avgs[len(avgs) // 2], mx, sum(1 for x in self.lat if x[2])))
        if self.churnres:
            out.append('churn    %d rounds; conversations %s' % (len(self.churnres), ' '.join('%d->%d' % (b, a) for b, a, _ in self.churnres[-6:])))
        for col, name in ((8, 'procs'), (9, 'tcp conversations'), (10, 'clock drift (s)')):
            s = [r[col] for r in rows if len(r) > col and r[col].lstrip('-').isdigit()]
            if s:
                out.append('%-17s first %s, last %s, min %s, max %s' % (name, s[0], s[-1], min(s, key=int), max(s, key=int)))
        if getattr(self, 'complaints', None):
            out.append('kernel complaints on serial: ' + ', '.join('%s x%d' % kv for kv in self.complaints.items()))
        for k, v in self.rates.items():
            ins = sorted(x[0] for x in v); outs = sorted(x[1] for x in v)
            out.append('%-7s %d transfers; median in %.0f, out %.0f Mbit/s' % (k, len(v), ins[len(ins) // 2], outs[len(outs) // 2]))
        tags = sorted(glob.glob(os.path.join(self.dir, 'memtags', '*.txt')), key=os.path.getmtime)
        if len(tags) >= 2:
            out.append('')
            out.append('call sites that grew most (memtags %s -> %s):' % (os.path.basename(tags[1] if len(tags) > 2 else tags[0]), os.path.basename(tags[-1])))
            out += self.tagdiff(tags[1] if len(tags) > 2 else tags[0], tags[-1])
        if self.batt:
            out.append('')
            out += ['battery %s %s: %s' % (b, w, r) for (b, w), r in sorted(self.batt.items())]
        text = '\n'.join(out) + '\n'
        open(os.path.join(self.dir, 'summary.txt'), 'w').write(text)
        print(text)
        os.makedirs(SOAKHOME, exist_ok=True)
        led = os.path.join(SOAKHOME, 'ledger.tsv')
        new = not os.path.exists(led)
        with open(led, 'a') as f:
            if new:
                f.write('start\tboard\tkernel_sha1\tkernel_bytes\thours\toptions\tresult\tfails\tmain_per_h\tskipped\trun_dir\n')
            s = series(2)
            slope = ''
            if len(s) > 12:
                a, b = floor(s, s[10][0]), floor(s, s[-1][0]); slope = '%.0f' % ((b - a) / max((s[-1][0] - s[10][0]) / 3600, 0.01))
            f.write('%s\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\n' % (
                time.strftime('%Y-%m-%d %H:%M', time.localtime(self.t0)), self.info.name, self.kernel[1], self.kernel[0],
                (time.time() - self.t0) / 3600, self.options().replace(' ', ','),
                'ALARM' if alarm else 'ok', sum(self.failcount.values()), slope,
                ','.join(n for n, s in self.state.items() if s.startswith('skip')), self.dir))

    def tagdiff(self, fa, fb):
        def load(f):
            d = {}
            for l in open(f):
                m = re.match(r'\s*(\d+)\s+(\d+)\s+(0x[0-9a-f]+)', l)
                if m:
                    d[m.group(3)] = (int(m.group(1)), int(m.group(2)))
            return d
        a, b = load(fa), load(fb)
        diff = sorted(((b.get(k, (0, 0))[0] - a.get(k, (0, 0))[0], k) for k in set(a) | set(b)), reverse=True)[:10]
        elf = self.a.elf
        names = {}
        if elf and os.path.exists(elf):
            pcs = [k for _, k in diff]
            res = subprocess.run(['llvm-symbolizer', '--obj=' + elf] + pcs, capture_output=True, text=True).stdout.strip().split('\n\n')
            names = {pc: r.split('\n')[0] for pc, r in zip(pcs, res)}
        return ['  %+9d bytes  %4d -> %-4d blocks  %s %s' % (g, a.get(k, (0, 0))[1], b.get(k, (0, 0))[1], k, names.get(k, ''))
                for g, k in diff if g]


def main():
    p = argparse.ArgumentParser(description='one soak for every Raspberry Pi (docs/SOAK.md)')
    p.add_argument('--board', required=True, help='a name in ~/pitools/boards')
    p.add_argument('--hours', type=float, default=12)
    p.add_argument('--profile', choices=sorted(PROFILES), default='normal', help='intensity of every area')
    p.add_argument('--stress', type=lambda s: s.split(','), default=[], help='areas raised to stress: ' + ','.join(AREAS))
    p.add_argument('--scratch', action='append', default=[], help='DEV=PART that may be written raw, e.g. nvme=#S/nvme0p2')
    p.add_argument('--vmstress', action='store_true')
    p.add_argument('--flood', action='store_true', help='console flood as a load')
    p.add_argument('--batteries', action='store_true', help='Ethernet, Bluetooth and GPIO batteries before and after')
    p.add_argument('--card', action='store_true', help='card.py against this tree first')
    p.add_argument('--serial-only', action='store_true')
    p.add_argument('--dry', action='store_true', help='probe and print the plan; change nothing on the board')
    p.add_argument('--loads', type=lambda s: s.split(','), default=None)
    p.add_argument('--skip', type=lambda s: s.split(','), default=[])
    p.add_argument('--elf', help='the running kernel\'s ELF, to name memtags call sites')
    a = p.parse_args()
    run = Run(a)
    signal.signal(signal.SIGTERM, lambda *x: run.stop.set())
    run.main()

if __name__ == '__main__':
    main()
