#!/usr/bin/env python3
# symbolise a /dev/memtags dump: symtags.py <kernel.elf> < memtags.txt
import sys, bisect, subprocess
elf = sys.argv[1]
out = subprocess.run(['llvm-nm', '-n', elf], capture_output=True, text=True).stdout
syms = [(int(l.split()[0], 16), l.split()[2]) for l in out.splitlines() if len(l.split()) == 3 and l.split()[1] in 'tTwW']
addrs = [a for a, _ in syms]
for line in sys.stdin:
    f = line.split()
    if len(f) == 3 and f[2].startswith('0x'):
        pc = int(f[2], 16)
        i = bisect.bisect_right(addrs, pc) - 1
        name = '%s+%#x' % (syms[i][1], pc - addrs[i]) if i >= 0 and pc >= addrs[0] and pc < 0x400000 else '?'
        print('%11s %9s  %-28s %s' % (f[0], f[1], name, f[2]))
    else:
        print(line.rstrip())
