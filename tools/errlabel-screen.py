#!/usr/bin/env python3
"""Screen compiled kernel error handlers for locals folded to stale values.

The kernels' waserror() is setjmp (hosted) or setlabel (native), and its
handler is reached by a longjmp.  C leaves a local that is changed after
the setjmp, and is not volatile, indeterminate in the handler.  clang
takes that literally: it gives the handler the value the local had at
waserror().  A handler written

	c = nil;
	if(waserror()){
		if(c != nil)
			cclose(c);
		nexterror();
	}
	c = something();

is compiled with no cclose in it at all, and one that closes a channel
which the guarded code replaced closes the old one a second time.

Given pairs of a C source file and its LLVM IR (clang -S -emit-llvm at
the flags the kernel is built with), this reports, for each handler:

  null    a call in the handler whose pointer argument is the constant
          null (a local folded to the nil it was at waserror());
  gone    a function the source's handler calls, defined in another
          file (so not inlined), that the compiled handler does not call.

It reads the IR as text and knows nothing of C: it is a screen, and a
handler it does not report has not been proved right.  A function whose
count of waserror() differs from its count of setjmp/setlabel calls
(static functions inlined into it) is not compared, and is listed with
-v.  Exit status 1 if anything is reported.

usage: errlabel-screen.py [-v] source.c ir.ll [source.c ir.ll ...]
"""
import os
import re
import sys

SKIP = set("""if while for switch sizeof nexterror error USED return defined
	waserror poperror
	nelem panic print iprint fprint snprint sprint memmove memset strcmp
	strcpy strlen""".split())


def blockend(text, start):
	k = start
	depth = 1
	while k < len(text) and depth:
		if text[k] == '{':
			depth += 1
		elif text[k] == '}':
			depth -= 1
		k += 1
	return k


def source(path):
	"""-> ({function: [set of names called in each handler]}, names defined)"""
	src = open(path, errors='replace').read()
	src = re.sub(r'/\*.*?\*/', lambda m: re.sub(r'[^\n]', ' ', m.group(0)), src, flags=re.S)
	src = re.sub(r'//[^\n]*', '', src)
	defined = set(re.findall(r'^([A-Za-z_]\w*)\([^;{]*\)\s*\n\{', src, re.M))
	defined |= set(re.findall(r'^#define\s+([A-Za-z_]\w*)\(', src, re.M))
	# and what the headers beside it define (inline functions, macros)
	d = os.path.dirname(path) or '.'
	for hd in (d, os.path.join(d, '..', 'port'), os.path.join(d, '..', 'bcm')):
		if not os.path.isdir(hd):
			continue
		for h in os.listdir(hd):
			if h.endswith('.h'):
				ht = open(os.path.join(hd, h), errors='replace').read()
				defined |= set(re.findall(r'^([A-Za-z_]\w*)\([^;{]*\)\s*\n\{', ht, re.M))
				defined |= set(re.findall(r'^#define\s+([A-Za-z_]\w*)\(', ht, re.M))
	res = {}
	for fm in re.finditer(r'^([A-Za-z_]\w*)\(([^)]*)\)\n\{\n(.*?)^\}', src, re.S | re.M):
		fname, body = fm.group(1), fm.group(3)
		hs = []
		for hm in re.finditer(r'(if|while)\s*\(\s*(!?)\s*waserror\(\)\s*(==\s*0)?\s*\)\s*(\{?)', body):
			neg = hm.group(2) == '!' or bool(hm.group(3))
			if hm.group(4) == '{':
				end = blockend(body, hm.end())
				first = body[hm.end():end]
			else:
				end = body.find(';', hm.end()) + 1
				first = body[hm.end():end]
			if neg:
				em = re.match(r'\s*else\s*(\{?)', body[end:])
				if em and em.group(1) == '{':
					s = end + em.end()
					handler = body[s:blockend(body, s)]
				elif em:
					s = end + em.end()
					handler = body[s:body.find(';', s) + 1]
				else:
					handler = ''
			else:
				handler = first
			hs.append((set(re.findall(r'\b([A-Za-z_]\w*)\s*\(', handler)) - SKIP, handler))
		if hs:
			res[fname] = hs
	return res, defined


def compiled(path):
	"""-> {function: [(calls in handler, [null-argument calls]) or None]}"""
	t = open(path).read()
	res = {}
	for fm in re.finditer(r'define[^\n]*@(\w+)\(.*?\n}\n', t, re.S):
		name = fm.group(1)
		text = fm.group(0)
		if 'setjmp' not in text and '@setlabel' not in text:
			continue
		f = text.split('\n')
		labels = {}
		for k, l in enumerate(f):
			m = re.match(r'^(\d+):', l)
			if m:
				labels[m.group(1)] = k

		def block(lab):
			out = []
			for l2 in f[labels[lab] + 1:]:
				if re.match(r'^\d+:', l2) or l2 == '}':
					break
				if l2.strip():
					out.append(l2)
			return out

		hs = []
		for i, l in enumerate(f):
			if not (('setjmp' in l or '@setlabel' in l) and 'call' in l):
				continue
			h = None
			r = re.match(r'\s*(%\d+) = ', l)
			if r:
				for k in range(i + 1, min(i + 6, len(f))):
					if 'icmp' in f[k] and r.group(1) in f[k]:
						eq = 'icmp eq' in f[k]
						cres = re.match(r'\s*(%\d+) = ', f[k]).group(1)
						for k2 in range(k + 1, min(k + 4, len(f))):
							if f[k2].strip().startswith('br i1 ' + cres):
								labs = re.findall(r'label %(\d+)', f[k2])
								h = labs[1] if eq else labs[0]
			if h is None or h not in labels:
				hs.append(None)
				continue
			seen = set()
			todo = [h]
			calls = set()
			nulls = []
			first = True
			while todo and len(seen) < 80:
				lab = todo.pop()
				if lab in seen or lab not in labels:
					continue
				seen.add(lab)
				b = block(lab)
				stop = False
				for l2 in b:
					for c in re.findall(r'call [^@\n]*@(\w+)\(', l2):
						calls.add(c)
					if first and 'llvm.' not in l2 and re.search(
							r'call [^@]*@\w+\((ptr noundef null|[^)]*, ptr noundef null)', l2):
						nulls.append(l2.strip()[:100])
					if '@nexterror' in l2:
						stop = True
				first = False
				if not stop and b:
					term = ' '.join(b) if any('switch' in x for x in b) else b[-1]
					todo.extend(re.findall(r'label %(\d+)', term))
			hs.append((calls, nulls))
		res[name] = hs
	return res


def main(argv):
	verbose = False
	if argv and argv[0] == '-v':
		verbose = True
		argv = argv[1:]
	if not argv or len(argv) % 2:
		sys.stderr.write(__doc__)
		return 2
	found = 0
	for i in range(0, len(argv), 2):
		sp, ip = argv[i], argv[i + 1]
		handlers, defined = source(sp)
		ir = compiled(ip)
		for fn in sorted(handlers):
			if fn not in ir:
				continue
			hs, ih = handlers[fn], ir[fn]
			alltext = ' '.join(h[1] for h in hs)
			for n, c in enumerate(ih):
				if c is not None:
					for call in c[1]:
						# a nil the source itself passes is no fold
						callee = re.search(r'@(\w+)\(', call).group(1)
						if re.search(r'\b' + callee + r'\([^;]*\b(nil|0)\b', alltext):
							continue
						print("%s: %s: null: %s" % (sp, fn, call))
						found += 1
			if len(hs) != len(ih):
				if verbose:
					print("%s: %s: not compared (%d handlers in the source, %d in the code)" % (sp, fn, len(hs), len(ih)))
				continue
			for n, ((sc, nil_), c) in enumerate(zip(hs, ih)):
				if c is None:
					continue
				# (a name all in capitals is a macro from a header, by
				# this tree's convention: D2H, FS, USED)
				gone = sorted(x for x in sc if x not in defined and x not in c[0]
					and '__' + x not in c[0] and x + '_chk' not in c[0]
					and not x.startswith('__builtin') and not re.match(r'^[A-Z][A-Z0-9_]*$', x))
				if gone:
					print("%s: %s: gone: handler %d calls %s in the source and not in the code" % (sp, fn, n + 1, ', '.join(gone)))
					found += 1
	return 1 if found else 0


if __name__ == '__main__':
	sys.exit(main(sys.argv[1:]))
