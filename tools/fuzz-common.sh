# tools/fuzz-common.sh — what the GUI fuzzers' drivers share
# (tools/xenith-fuzz, tools/wm-fuzz); sourced, with ROOT set.
#
#	sandbox dir	make dir an emulator root: a copy of what the
#			applications need, the other directories empty, as
#			mount points.  Random use opens files by name and saves
#			them (in Xenith a directory's listing, B3 on a name in
#			it, typing, Put; in a shell, what is typed), so in the
#			tree itself it changed tracked files.
#	mapstacks log	the log, its stacks (lines "fp pc mp prog type
#			path") as source lines, through the .sbl files mk leaves
#			beside each .b

sandbox() {
	sb=$1
	rm -rf "${sb:?}"
	mkdir -p "$sb/tmp" "$sb/tests"
	for d in "$ROOT"/*/; do
		d=$(basename "$d")
		case $d in
		dis|lib|fonts|icons|locale|usr|mnt|n)	cp -a "$ROOT/$d" "$sb/$d" ;;
		tmp|tests)	;;
		*)	mkdir -p "$sb/$d" ;;
		esac
	done
	for d in page imgload xenith; do
		cp -a "$ROOT/tests/$d" "$sb/tests/$d"
	done
	mkdir -p "$sb/usr/$(id -un)"	# a home, for Dump and Load
}

mapstacks() {
	command -v python3 >/dev/null 2>&1 || { cat "$1"; return; }
	python3 - "$ROOT" "$1" <<'EOF'
import re, sys, os
root, log = sys.argv[1], sys.argv[2]
cache = {}
def sbl(dis):
	if dis in cache:
		return cache[dis]
	m = dis.replace('/dis/', '', 1)[:-4]
	pcs = None
	for c in (root+'/appl/'+m+'.sbl', root+'/appl/xenith/'+os.path.basename(m)+'.sbl',
	          root+'/appl/'+m+'/'+os.path.basename(m)+'.sbl', root+'/'+m+'.sbl'):
		try:
			L = open(c).read().split('\n')
		except OSError:
			continue
		n = int(L[2]); files = L[3:3+n]; i = 3+n; npc = int(L[i]); i += 1
		lf = ll = 0; pcs = []
		for k in range(npc):
			a, b = L[i+k].rsplit(' ', 1)[0].split(',')
			def part(x, f, l):
				if ':' in x: f, x = x.split(':'); f = int(f)
				if '.' in x: l, x = x.split('.'); l = int(l)
				return f, l
			sf, sl = part(a, lf, ll); ef, el = part(b, sf, sl)
			pcs.append('%s:%d' % (files[sf], sl)); lf, ll = ef, el
		break
	cache[dis] = pcs
	return pcs
for line in open(log, errors='replace'):
	m = re.match(r'^\S+ ([0-9a-f]{8}) \S+ \S+ \S+ (\S+\.dis)\s*$', line)
	if m:
		pcs = sbl(m.group(2)); pc = int(m.group(1), 16)
		print('\t' + (pcs[pc] if pcs and pc < len(pcs) else '%s pc %d' % (m.group(2), pc)))
	else:
		print(line, end='')
EOF
}
