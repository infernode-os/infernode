#!/usr/bin/env python3
# Makes vectors.txt for tests/host/libmp_edge_test.sh: answers from
# Python's integers for libmp's division, remainder and text.
#
#	python3 gen.py > vectors.txt
#
# div a b q r	a/b truncated towards zero, the remainder with a's sign
#		(libmp's mpdiv, C's / and %)
# mod a m r	the least r >= 0 with a = r mod |m|
# txt base n text	n written in base 10, 16, 32 or 64 as mptoa writes it
#
# Numbers are hexadecimal with a leading - for a negative one. Base 32
# and 64 are the number's big-endian bytes encoded (base 32 in Plan 9's
# alphabet, with bytes of zero in front to a multiple of five).
import base64, random

random.seed(20261116)

def h(n):
	return ('-' if n < 0 else '') + '%x' % abs(n)

def tdiv(a, b):
	q = abs(a) // abs(b)
	if (a < 0) != (b < 0):
		q = -q
	return q, a - q*b

def nums():
	l = [0, 1, 2, 3, 5, 6, 7, 255, 256, 65535, 65536, 2**32-1, 2**32, 2**32+1,
		2**64-1, 2**64, 2**96-1, 10**9, 10**9-1, 10**18, 10**18+5, 2**1024-1, 2**1024]
	for bits in (8, 31, 32, 33, 63, 64, 65, 100, 255, 256, 257, 1000, 2048, 4099):
		for i in range(6):
			l.append(random.getrandbits(bits) | 1 << (bits-1))
	# digits of all ones and of zero, which mpdiv's trial quotients meet
	for nd in (2, 3, 5, 9):
		l.append((2**32-1) << (32*(nd-1)))
		l.append(2**(32*nd) - 1)
		l.append(2**(32*nd) - 2**32)
	return l

N = nums()
out = []
for i in range(1500):
	a = random.choice(N) * random.choice((1, -1))
	b = random.choice(N[1:]) * random.choice((1, -1))
	q, r = tdiv(a, b)
	out.append('div %s %s %s %s' % (h(a), h(b), h(q), h(r)))
	out.append('mod %s %s %s' % (h(a), h(b), h(a % abs(b))))

T32 = '23456789abcdefghijkmnpqrstuvwxyz'
B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'

def bebytes(n):
	return n.to_bytes(max(1, (n.bit_length()+7)//8), 'big')

def b32(n):
	b = bebytes(n)
	b = bytes((5 - len(b) % 5) % 5) + b
	return ''.join(T32[B32.index(c)] for c in base64.b32encode(b).decode())

def b64(n):
	return base64.b64encode(bebytes(n)).decode()

for n in N + [random.getrandbits(random.randrange(1, 3000)) for i in range(300)]:
	for s in (1, -1):
		if n == 0 and s < 0:
			continue
		sg = '-' if s < 0 else ''
		out.append('txt 10 %s %s%d' % (h(s*n), sg, n))
		out.append('txt 16 %s %s%X' % (h(s*n), sg, n))
		out.append('txt 32 %s %s%s' % (h(s*n), sg, b32(n)))
		out.append('txt 64 %s %s%s' % (h(s*n), sg, b64(n)))
print('\n'.join(out))
