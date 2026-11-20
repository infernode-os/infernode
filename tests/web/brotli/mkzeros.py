#!/usr/bin/env python3
# The smallest Brotli streams that decode to a great many bytes, for
# tests/brotli_test.b: there is no Brotli encoder in the tree, so these
# are written by hand from RFC 7932 section 9.
#
#	mkzeros.py DIR
#
# writes DIR/zeros-1m.br (1,000,000 zero bytes; its .out is not kept:
# the test knows what it is) and DIR/zeros-96m.br (six meta-blocks of
# 2^24 zero bytes each: 100,663,296 bytes from under a hundred).
#
# Each meta-block is one command: insert one literal (0), then copy
# MLEN-1 bytes from distance 1.  All three prefix codes are simple codes
# of one symbol, which cost no bits where they are used:
#	literal 0
#	insert-and-copy 399: insert length code 1 (one literal), copy
#		length code 23 (2118 and 24 extra bits), explicit distance
#	distance 16: with NPOSTFIX 0 and NDIRECT 0, one extra bit, which
#		as 0 says distance 1
#
# With node on the path the streams are checked against its zlib (the
# reference decoder) before they are written.

import sys, os, subprocess, shutil

class Bits:
    def __init__(self):
        self.acc = 0
        self.n = 0
    def put(self, v, k):		# k bits of v, least significant first
        self.acc |= v << self.n
        self.n += k
    def bytes(self):
        return self.acc.to_bytes((self.n + 7) // 8, 'little')

def simple(b, sym, abits):
    b.put(1, 2)		# HSKIP 1: a simple prefix code
    b.put(0, 2)		# NSYM - 1
    b.put(sym, abits)

def metablock(b, mlen):
    assert 2119 <= mlen <= 1 << 24
    b.put(0, 1)			# ISLAST
    # MLEN - 1 in the fewest nibbles of four, five or six
    nib = max(4, ((mlen - 1).bit_length() + 3) // 4)
    b.put(nib - 4, 2)		# MNIBBLES
    b.put(mlen - 1, 4 * nib)
    b.put(0, 1)			# ISUNCOMPRESSED
    b.put(0, 1)			# NBLTYPESL = 1
    b.put(0, 1)			# NBLTYPESI = 1
    b.put(0, 1)			# NBLTYPESD = 1
    b.put(0, 2)			# NPOSTFIX
    b.put(0, 4)			# NDIRECT
    b.put(0, 2)			# context mode of the one literal block type
    b.put(0, 1)			# NTREESL = 1
    b.put(0, 1)			# NTREESD = 1
    simple(b, 0, 8)		# literals: 0
    simple(b, 399, 10)		# insert-and-copy
    simple(b, 16, 6)		# distances
    b.put(mlen - 1 - 2118, 24)	# copy length's extra bits
    b.put(0, 1)			# distance's extra bit: distance 1

def stream(lens):
    b = Bits()
    b.put(0, 1)			# WBITS 16
    for n in lens:
        metablock(b, n)
    b.put(3, 2)			# ISLAST, ISLASTEMPTY
    return b.bytes()

def check(data, total):
    node = shutil.which('node')
    if node is None:
        return
    js = ("const z=require('zlib');let d=Buffer.from(process.argv[1],'hex');"
          "let o=z.brotliDecompressSync(d,{maxOutputLength:1<<28});"
          "if(o.length!=%d||o.some(x=>x!=0))process.exit(1)" % total)
    subprocess.run([node, '-e', js, data.hex()], check=True)

d = sys.argv[1]
for name, lens in (('zeros-1m.br', [1000000]), ('zeros-96m.br', [1 << 24] * 6)):
    s = stream(lens)
    check(s, sum(lens))
    with open(os.path.join(d, name), 'wb') as f:
        f.write(s)
    print(name, len(s), 'bytes for', sum(lens))
