#!/usr/bin/env python3
#
# winsuite.py -- the Limbo tests under the Windows emulator, each in an
# emulator of its own, under each Dis VM mode.
#
#	python tests/host/winsuite.py [-m "-c0;-c1"] [-t secs] [-j jobs]
#		[-o logdir] [-v] [-e emu] [test ...]
#
# A test is a name (spawn, or spawn_test) or a /dis path; with none,
# every dis/tests/*_test.dis. Each test runs through sh, which halts emu
# after it (emu does not exit when its first Prog dies), under each mode
# one after the other: tests use fixed names in /tmp, and two runs of one
# test at once collide. Different tests run at once (-j).
#
# A run is
#	PASS	its summary says so: "N passed[, 0 failed]", "PASS", "NAME PASS"
#	SKIP	it raised skip:..., or skipped every test it has
#	FAIL	a failed test, a fail:... raise, a Broken Prog
#	CRASH	emu died of an exception (any NTSTATUS from 0xC0000000), or
#		printed a trap, a panic or a faulting kernel process
#	HANG	still running after -t seconds (killed with its children)
#	?	none of these: no summary it knows
# Exit status 0 when every run is PASS or SKIP, 1 otherwise.
#
# tests/host/*.sh are the host's own tests and are not run here; the
# Windows CI job runs this and tests/runner.dis.
#

import argparse
import concurrent.futures
import os
import platform
import re
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
WINDOWS = platform.system() == "Windows"

if WINDOWS:
	import ctypes
	# a child that faults dies with its status, not in a dialog
	ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)

CRASH = re.compile(r"ACCESS VIOLATION|panic:|unknown trap type|SYS: process .* faults|vmwatchdog: VM token (STUCK|LOST)")
PASSED = re.compile(r"(?m)^[1-9][0-9]* passed(, 0 failed)?|^PASS$|^[A-Za-z_0-9]+:? PASS\b")
SKIPPED = re.compile(r'(?m)Broken: "skip:|^--- SKIP|\bSKIP \(')
FAILED = re.compile(r"(?m)^FAIL$|^--- FAIL|fail:|Broken: ")


def norm(t):
	if t.startswith("/"):
		return t
	if t.endswith(".dis"):
		t = t[:-4]
	if not t.endswith("_test"):
		t += "_test"
	return "/dis/tests/" + t + ".dis"


def killtree(p):
	if WINDOWS:
		subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)], capture_output=True)
	else:
		p.kill()


def one(emu, t, mode, secs, args):
	cmd = [emu] + mode.split() + ["-r" + ROOT, "/dis/sh.dis", "-c", "%s %s; echo halt > /dev/sysctl" % (t, args)]
	kw = {"creationflags": subprocess.CREATE_NEW_PROCESS_GROUP} if WINDOWS else {"start_new_session": True}
	t0 = time.time()
	p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, **kw)
	try:
		out, _ = p.communicate(timeout=secs)
		hung = False
	except subprocess.TimeoutExpired:
		killtree(p)
		out, _ = p.communicate()
		hung = True
	text = out.decode("utf-8", "replace")
	rc = (p.returncode or 0) & 0xFFFFFFFF
	if hung:
		v = "HANG"
	elif rc >= 0xC0000000:
		v = "CRASH %#x" % rc
	elif CRASH.search(text):
		v = "CRASH"
	elif PASSED.search(text) and not FAILED.search(text):
		v = "PASS"
	elif SKIPPED.search(text) and not re.search(r"(?m)^--- FAIL", text):
		v = "SKIP"
	elif FAILED.search(text):
		v = "FAIL"
	else:
		v = "?"
	return t, mode, v, time.time() - t0, text


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("-m", default="-c0;-c1", help="';'-separated emu flags, one run each")
	ap.add_argument("-t", type=int, default=240, help="seconds for one run")
	ap.add_argument("-j", type=int, default=max(1, (os.cpu_count() or 2) // 2))
	ap.add_argument("-o", default=None, help="keep each run's output here")
	ap.add_argument("-e", default=None, help="the emulator (emu/Nt/o.emu.exe)")
	ap.add_argument("-a", default="", help="arguments to each test")
	ap.add_argument("-v", action="store_true", help="the tail of each run that did not pass")
	ap.add_argument("tests", nargs="*")
	a = ap.parse_args()

	emu = a.e or os.path.join(ROOT, "emu", "Nt" if WINDOWS else platform.system(), "o.emu" + (".exe" if WINDOWS else ""))
	if not os.path.exists(emu):
		sys.exit("winsuite: no %s" % emu)
	tests = [norm(t) for t in a.tests]
	if not tests:
		d = os.path.join(ROOT, "dis", "tests")
		tests = sorted("/dis/tests/" + f for f in os.listdir(d) if f.endswith("_test.dis"))
	modes = [m.strip() for m in a.m.split(";") if m.strip()]

	res = {}
	t0 = time.time()
	with concurrent.futures.ThreadPoolExecutor(a.j) as ex:
		futs = [ex.submit(lambda t: [one(emu, t, m, a.t, a.a) for m in modes], t) for t in tests]
		for f in concurrent.futures.as_completed(futs):
			for t, m, v, s, text in f.result():
				res[(t, m)] = (v, s, text)
				if a.o:
					os.makedirs(a.o, exist_ok=True)
					fn = os.path.basename(t) + m.replace(" ", "") + ".log"
					with open(os.path.join(a.o, fn), "w", encoding="utf-8") as fh:
						fh.write(text)

	bad = []
	counts = {}
	for t in tests:
		vs = [res[(t, m)][0] for m in modes]
		for v in vs:
			k = v.split()[0]
			counts[k] = counts.get(k, 0) + 1
		ok = all(v in ("PASS", "SKIP") for v in vs)
		print("%-44s %s" % (os.path.basename(t), "  ".join("%s %-10s" % (m, v) for m, v in zip(modes, vs))), flush=True)
		if not ok:
			bad.append(t)
			if a.v:
				for m in modes:
					v, s, text = res[(t, m)]
					if v not in ("PASS", "SKIP"):
						lines = [l for l in text.splitlines() if not l.startswith(("=== RUN", "--- PASS"))]
						print("    [%s] %s" % (m, "\n    ".join(lines[-15:])))
	print("winsuite: %d tests, %d modes, %.0fs: %s; %d not passing" % (len(tests), len(modes), time.time() - t0,
		" ".join("%s %d" % kv for kv in sorted(counts.items())), len(bad)))
	if bad:
		print("not passing: " + " ".join(os.path.basename(t)[:-len("_test.dis")] for t in bad))
	return 1 if bad else 0


if __name__ == "__main__":
	sys.exit(main())
