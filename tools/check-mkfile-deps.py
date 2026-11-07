#!/usr/bin/env python3
#
# check-mkfile-deps.py [-fix] — every module header a Limbo source
# includes is a prerequisite of its .dis in the mkfile that builds it.
#
# mkfiles/mkdis makes each .dis depend on the headers its directory
# names: MODULES (paths from the directory) and SYSMODULES (paths in
# module/).  A header a source includes and the mkfile does not name
# changes without mk seeing it: the .dis is left as it was, and the Dis
# VM refuses it at load ("link typecheck") until someone happens to
# rebuild it.  hooks/post-merge's rebuild after a change to module/ is
# mk install in each directory, so it left them too.
#
# Includes are followed as limbo finds them (limbo/lex.c includef):
# from the source's directory, then each -I directory, then module/,
# and through the headers they include in turn.  Checked: the mkfiles
# under appl/ and tests/ that read mkfiles/mkdis (a header must be in
# MODULES or SYSMODULES as they stand where mkdis is read: mk expands
# a variable when it reads it), and appl/veltro's, which names each
# target's headers in its rule.
#
# -fix adds what is missing: to SYSMODULES (made before mkdis if there
# is none) for a header in module/, to MODULES for one beside the
# sources, to the target's rule in appl/veltro.  Exit 1 if anything is
# missing (and -fix was not given).
#
import os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
MODDIR = os.path.join(ROOT, 'module')
INCLUDE = re.compile(r'^\s*include\s+"([^"]+)"', re.M)

def rel(p):
	return os.path.relpath(p, ROOT)

def logical(text):
	# mk's lines: a backslash at the end joins the next
	out, cur, start = [], '', None
	for n, line in enumerate(text.split('\n')):
		if start is None:
			start = n
		if line.endswith('\\'):
			cur += line[:-1] + ' '
			continue
		out.append((start, n, cur + line))
		cur, start = '', None
	return out

def expand(s, env, depth=0):
	if depth > 10:
		return s
	def sub(m):
		name = m.group(1) or m.group(2)
		v = env.get(name)
		if v is None:
			return m.group(0)
		return expand(v, env, depth + 1)
	return re.sub(r'\$\{(\w+)\}|\$(\w+)', sub, s)

ASSIGN = re.compile(r'^(\w+)\s*=(?!=)\s*(.*)$')

def mkvars(text, upto=None):
	# variables as mk has them at line upto (all of them if None)
	env = {'ROOT': ROOT, 'MODDIR': MODDIR}
	for start, end, line in logical(text):
		if upto is not None and start >= upto:
			break
		if line.startswith('\t') or line.startswith(' '):
			continue
		m = ASSIGN.match(line)
		if m:
			env[m.group(1)] = expand(m.group(2).strip(), env)
	return env

def incdirs(env, d):
	dirs = []
	for flag in re.findall(r'-I\s*(\S+)', env.get('LIMBOFLAGS', '')):
		dirs.append(os.path.normpath(os.path.join(d, flag)))
	return dirs + [MODDIR]

def closure(src, dirs):
	# every header src includes, at any depth, as limbo would open it
	srcdir = os.path.dirname(src)
	seen, todo, missing = set(), [src], set()
	while todo:
		f = todo.pop()
		try:
			text = open(f, errors='replace').read()
		except OSError:
			continue
		for name in INCLUDE.findall(text):
			if name.startswith('/'):
				cands = [os.path.join(ROOT, name[1:])]
			else:
				cands = [os.path.join(srcdir, name)] + [os.path.join(i, name) for i in dirs]
			for c in cands:
				c = os.path.normpath(c)
				if os.path.isfile(c):
					if c not in seen:
						seen.add(c)
						todo.append(c)
					break
			else:
				missing.add(name)
	return seen

def tracked(path):
	r = subprocess.run(['git', '-C', ROOT, 'ls-files', '--error-unmatch', rel(path)],
		capture_output=True)
	return r.returncode == 0

def mkdislists(text, d):
	# MODULES and SYSMODULES as they stand where mkdis is read
	lines = text.split('\n')
	at = next(i for i, l in enumerate(lines) if l.startswith('<') and l.rstrip().endswith('mkdis'))
	env = mkvars(text, at)
	have = set()
	for m in env.get('MODULES', '').split():
		have.add(os.path.normpath(os.path.join(d, m)))
	for m in env.get('SYSMODULES', '').split():
		have.add(os.path.normpath(os.path.join(MODDIR, m)))
	return env, at, have

def targets(env, d):
	srcs = []
	for t in env.get('TARG', '').split():
		if t.endswith('.dis'):
			b = os.path.join(d, t[:-4] + '.b')
			if os.path.isfile(b):
				srcs.append(b)
	return srcs

def checkmkdis(mk):
	d = os.path.dirname(mk)
	text = open(mk).read()
	env, at, have = mkdislists(text, d)
	unset = [v for v in ('MODULES', 'SYSMODULES') if v not in env]
	full = mkvars(text)
	dirs = incdirs(full, d)
	need = {}
	for b in targets(full, d):
		for h in closure(b, dirs):
			if h not in have and h.endswith('.m') and tracked(h):
				need.setdefault(h, []).append(os.path.basename(b))
	return need, unset

# A header beside the mkfile or below it by its path from there; one
# elsewhere from $ROOT, as a relative path is wrong in the mk of a
# subdirectory that inherits the list.
def modname(h, d):
	r = os.path.relpath(h, d)
	if r.startswith('..'):
		return '$ROOT/' + rel(h)
	return r

def fixmkdis(mk, need, unset):
	d = os.path.dirname(mk)
	text = open(mk).read()
	sysm = sorted(rel(h)[len('module/'):] for h in need if h.startswith(MODDIR + os.sep))
	locm = sorted(modname(h, d) for h in need if not h.startswith(MODDIR + os.sep))
	for var, names in (('SYSMODULES', sysm), ('MODULES', locm)):
		lines = text.split('\n')
		at = next(i for i, l in enumerate(lines) if l.startswith('<') and l.rstrip().endswith('mkdis'))
		defs = [(s, e) for s, e, l in logical(text) if s < at and re.match(var + r'\s*=(?!=)', l)]
		add = ['\t%s\\' % n for n in names]
		if not defs:
			# set even when empty: an unset one is the parent mk's
			lines[at:at] = ['%s=\\' % var] + add + [''] if names else ['%s=' % var, '']
		elif names:
			s, e = defs[-1]
			if s < e:
				# a list continued over lines: before its last line
				lines[e:e] = add
			else:
				# NAME=a b, or NAME= alone: continued from it
				lines[e] += '\\'
				add[-1] = add[-1][:-1]
				lines[e+1:e+1] = add
		text = '\n'.join(lines)
	open(mk, 'w').write(text)

RULE = re.compile(r'^([\w./-]+\.dis):\s*(.*)$')

def checkrules(mk):
	# appl/veltro: each target's headers named in its own rule
	d = os.path.dirname(mk)
	text = open(mk).read()
	env = mkvars(text)
	dirs = incdirs(env, d)
	need = {}
	for start, end, line in logical(text):
		m = RULE.match(line)
		if not m:
			continue
		prereq = expand(m.group(2), env).split()
		srcs = [os.path.join(d, p) for p in prereq if p.endswith('.b')]
		if not srcs:
			continue
		have = {os.path.normpath(os.path.join(d, p)) for p in prereq}
		for h in closure(srcs[0], dirs):
			if h not in have and h.endswith('.m') and tracked(h):
				need.setdefault((m.group(1), end), []).append(h)
	return need

def fixrules(mk, need):
	d = os.path.dirname(mk)
	lines = open(mk).read().split('\n')
	for (target, end), hs in sorted(need.items(), key=lambda x: -x[0][1]):
		names = []
		for h in sorted(hs):
			names.append('$MODDIR/' + rel(h)[len('module/'):] if h.startswith(MODDIR + os.sep)
				else modname(h, d))
		lines[end] = lines[end].rstrip() + ' ' + ' '.join(names)
	open(mk, 'w').write('\n'.join(lines))

def main():
	fix = sys.argv[1:] == ['-fix']
	if sys.argv[1:] and not fix:
		sys.exit('usage: check-mkfile-deps.py [-fix]')
	mkfiles = subprocess.run(['git', '-C', ROOT, 'ls-files', 'appl', 'tests'],
		capture_output=True, text=True).stdout.split()
	mkfiles = [os.path.join(ROOT, f) for f in mkfiles if os.path.basename(f) == 'mkfile']
	bad = 0
	for mk in sorted(mkfiles):
		text = open(mk).read()
		if re.search(r'^<.*mkdis\s*$', text, re.M):
			need, unset = checkmkdis(mk)
			for v in unset:
				print('%s: %s not set before mkdis (a parent mk\'s would be used)' % (rel(mk), v))
			for h, users in sorted(need.items()):
				print('%s: %s not named (included by %s)' % (rel(mk), rel(h), ', '.join(sorted(set(users)))))
			if (need or unset) and fix:
				fixmkdis(mk, need, unset)
			bad += len(unset)
		elif re.search(r'^\s+limbo\s', text, re.M):
			need = checkrules(mk)
			for (target, end), hs in sorted(need.items()):
				print('%s: %s does not depend on %s' % (rel(mk), target, ', '.join(rel(h) for h in sorted(hs))))
			if need and fix:
				fixrules(mk, need)
		else:
			continue
		bad += len(need)
	if bad and not fix:
		print('%d missing; tools/check-mkfile-deps.py -fix adds them' % bad)
		sys.exit(1)
	if not bad:
		print('OK: every header a source includes is named in its mkfile')

if __name__ == '__main__':
	main()
