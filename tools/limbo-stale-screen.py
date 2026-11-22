#!/usr/bin/env python3
#
# limbo-stale-screen.py [-v] file.s ...
#
# Screens assembly from "limbo -S" for an address inside a heap object
# that is kept across something that can free the object.  Limbo has no
# pointers to take, but the code generated for it does: indx and its
# kin give the address of an array's element, and an operand like
# 8(0(mp)) is found when its instruction starts.
#
#   kept	an instruction that waits, or that hands an address on, with
#		such an operand: a recv's destination and a send's source
#		(a Prog blocked in one keeps the address until the other
#		side comes), a load's destination and path (it lets other
#		Progs run while it reads the file), and what a lea takes the
#		address of (for a call's result, or an alt's table).  The
#		operand may be in the frame, in the module's data, or in an
#		object a frame slot holds that was not made by indx; not in
#		an object a global names (N(M(mp))), which another Prog can
#		drop meanwhile, and not at an element's address.
#
#   stale	an element's address (the middle operand of indx, indw, indl,
#		indf, indb) used after an instruction that can free the
#		array it is in: a call, spawn, send, recv, alt or load (they
#		run other code), a backward branch (where compiled code
#		gives the processor up), or a pointer stored in a global, in
#		an object, or over the frame slot the array was found from.
#
# The compiler holds a value, not its address, across such code
# (limbo/ecom.c: canfree, eacomv, stayput); tests/limbo_stale_test.b
# has a case for each form by behaviour, and this looks at what is
# generated for whole programs.  It is a screen over the text, read
# straight through with no flow analysis and no types, not a proof: it
# does not know a variable from a temporary, so a field of what a local
# variable names is taken to be safe where the compiler takes more care.
#
# -v prints each finding; the last line counts them.  Exit status 1 if
# there are any, 2 for usage.
#

import collections
import re
import sys

IND = {'indx', 'indw', 'indl', 'indf', 'indb'}
BLOCK = {'call', 'mcall', 'spawn', 'mspawn', 'send', 'recv', 'alt', 'nbalt', 'load'}
# instructions whose destination is a pointer: what was there is let go
PTRW = {'movp', 'movmp', 'new', 'newz', 'mnewz', 'newa', 'newaz', 'newcw', 'newcb',
	'newcl', 'newcf', 'newcp', 'newcm', 'newcmp', 'headp', 'headmp', 'tail',
	'slicea', 'slicec', 'cvtac', 'cvtca', 'cvtwc', 'cvtfc', 'cvtlc', 'addc',
	'insc', 'self', 'consb', 'consw', 'consl', 'consf', 'consp', 'consm', 'consmp'}
FRESH = {'new', 'newz', 'mnewz', 'newa', 'newaz'}
NOTCODE = {'entry', 'desc', 'var', 'module', 'link', 'ldts', 'source', 'string',
	'word', 'long', 'real', 'byte', 'array', 'indir', 'apop', 'ext', 'exc', 'exctab'}
BRANCH = re.compile(r'^(jmp|b[a-z]+)$')
OPERAND = re.compile(r'^(-?\d+)\((?:(-?\d+)\()?(fp|mp)\)\)?$')

def operand(o):
	"""(kind, slot, offset): kind imm, fp, mp, fpind, mpind or ?"""
	if o.startswith('$'):
		return ('imm', None, o[1:])
	m = OPERAND.match(o)
	if not m:
		return ('?', None, o)
	a, b, r = m.group(1), m.group(2), m.group(3)
	if b is None:
		return (r, int(a), None)
	return (r + 'ind', int(b), int(a))

def screen(path):
	lines = open(path, errors='replace').read().split('\n')
	insts = []
	for l in lines:
		if not l.startswith('\t'):
			continue
		f = l.strip().split('\t')
		if f[0] in NOTCODE:
			continue
		insts.append((f[0], f[1].split(',') if len(f) > 1 and f[1] != '' else [], l.strip()))

	# the nil slot is what pointer temporaries are cleared from; a load of
	# "$self" reads no file
	cnt = collections.Counter()
	for op, args, l in insts:
		if op == 'movp' and len(args) == 2:
			s, d = operand(args[0]), operand(args[1])
			if s[0] == 'mp' and d[0] == 'fp':
				cnt[s[1]] += 1
	nilslot = cnt.most_common(1)[0][0] if cnt else None
	selfslot = None
	for l in lines:
		m = re.match(r'^\tstring\t@mp\+(\d+),"\$self"$', l)
		if m:
			selfslot = int(m.group(1))

	raw = {}	# frame slot -> [tainted, by what, made by, slots the array was found from]
	held = set()	# frame slots holding a pointer
	fresh = set()	# frame slots holding an object or a frame just made
	found = []

	def taint(why, slot=None):
		for b in raw:
			if not raw[b][0] and (slot is None or slot in raw[b][3]):
				raw[b][0] = True
				raw[b][1] = why

	for pc, (op, args, l) in enumerate(insts):
		ops = [operand(a) for a in args]
		for o in ops:
			if o[0] == 'fpind' and o[1] in raw and raw[o[1]][0]:
				found.append(('stale', pc, l, 'address made by "%s" used after "%s"' % (raw[o[1]][2], raw[o[1]][1])))

		kept = []
		if op == 'recv' and len(args) == 2:
			kept = [1]
		elif op == 'send' and len(args) == 2:
			kept = [0]
		elif op == 'load' and len(args) == 3:
			kept = [2, 0]
		elif op == 'lea' and len(args) == 2:
			kept = [0]
		for i in kept:
			k, b, off = ops[i]
			if k == 'mpind':
				found.append(('kept', pc, l, '%s is in an object a global names' % args[i]))
			elif k == 'fpind' and b in raw:
				found.append(('kept', pc, l, '%s is at an address made by "%s"' % (args[i], raw[b][2])))

		if op in ('ret', 'exit', 'raise'):
			raw.clear()
			held.clear()
			fresh.clear()
			continue

		# what can free
		if op in BLOCK:
			if not (op == 'load' and ops[0][0] == 'mp' and ops[0][1] == selfslot):
				taint(l)
		elif BRANCH.match(op) and args and args[-1].startswith('$'):
			try:
				if int(args[-1][1:]) <= pc:
					taint(l)
			except ValueError:
				pass
		elif op in PTRW and not op.startswith('cons') and args:
			# (a cons keeps what its destination held, as the new cell's tail)
			d = ops[-1]
			if d[0] == 'mp' or d[0] == 'mpind':
				taint(l)
			elif d[0] == 'fp':
				if d[1] in held:
					taint(l, d[1])
			elif d[0] == 'fpind' and d[1] not in raw and d[1] not in fresh:
				taint(l)
		elif op == 'slicela' and len(args) == 3:
			d = ops[2]
			if not (d[0] == 'fpind' and d[1] in raw) and not (d[0] == 'fp' and d[1] in fresh):
				taint(l)

		# what the instruction leaves in the frame
		if op in IND and len(args) == 3:
			d = ops[1]
			if d[0] == 'fp':
				via = set()
				s = ops[0]
				if s[0] in ('fp', 'fpind'):
					via.add(s[1])
					if s[0] == 'fpind' and s[1] in raw:
						via |= raw[s[1]][3]
				raw[d[1]] = [False, None, l, via]
				held.discard(d[1])
				fresh.discard(d[1])
		elif op == 'lea' and len(args) == 2:
			d = ops[1]
			if d[0] == 'fp':
				raw.pop(d[1], None)
				held.discard(d[1])
				fresh.discard(d[1])
			s = ops[0]
			if s[0] == 'fp':
				# where a call's result goes
				raw.pop(s[1], None)
				held.add(s[1])
				fresh.discard(s[1])
		elif args:
			d = ops[-1]
			if op in ('call', 'mcall', 'spawn', 'mspawn', 'goto', 'case', 'casec', 'casel') or BRANCH.match(op):
				continue
			if d[0] == 'fp':
				raw.pop(d[1], None)
				fresh.discard(d[1])
				if op in PTRW:
					s = ops[0]
					if op == 'movp' and s[0] == 'mp' and s[1] == nilslot:
						held.discard(d[1])
					else:
						held.add(d[1])
						if op in FRESH:
							fresh.add(d[1])
				else:
					held.discard(d[1])
					if op in ('frame', 'mframe'):
						fresh.add(d[1])
	return found

def main():
	args = sys.argv[1:]
	verbose = False
	if args and args[0] == '-v':
		verbose = True
		args = args[1:]
	if not args or args[0].startswith('-'):
		sys.stderr.write('usage: limbo-stale-screen.py [-v] file.s ...\n')
		sys.exit(2)
	total = collections.Counter()
	bad = 0
	for p in args:
		f = screen(p)
		if f:
			bad += 1
		for kind, pc, l, why in f:
			total[kind] += 1
			if verbose:
				print('%s: pc %d: %s: %s: %s' % (p, pc, kind, l, why))
	print('%d files, %d with findings: %d kept, %d stale' % (len(args), bad, total['kept'], total['stale']))
	sys.exit(1 if bad else 0)

main()
