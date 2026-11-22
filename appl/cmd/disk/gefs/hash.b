#
# gefs: the hashes, as 9front's hash.c: MetroHash64-1 (J. Andrew Rogers,
# MIT licence) with seed 0x6765, over little-endian words, for block and
# superblock checksums; and the splitmix finaliser for hash tables.
#
# Limbo's big is signed, so a right shift brings sign bits in: lsr()
# is the logical one. Products wrap modulo 2^64, as in C.
#

lsr(x: big, k: int): big
{
	if(k == 0)
		return x;
	return (x >> k) & ((big 1 << (64-k)) - big 1);
}

rotr(v: big, k: int): big
{
	return lsr(v, k) | (v << (64-k));
}

le64(b: array of byte, o: int): big
{
	return big b[o] | (big b[o+1]<<8) | (big b[o+2]<<16) | (big b[o+3]<<24)
		| (big b[o+4]<<32) | (big b[o+5]<<40) | (big b[o+6]<<48) | (big b[o+7]<<56);
}

le32(b: array of byte, o: int): big
{
	return big b[o] | (big b[o+1]<<8) | (big b[o+2]<<16) | (big b[o+3]<<24);
}

le16(b: array of byte, o: int): big
{
	return big b[o] | (big b[o+1]<<8);
}

metrohash64(key: array of byte, n: int, seed: int): big
{
	k0 := big 16rC83A91E1;
	k1 := big 16r8648DBDB;
	k2 := big 16r7BDEC03B;
	k3 := big 16r2F5870A5;

	p := 0;
	hash := ((big seed + k2) * k0) + big n;
	if(n >= 32){
		v0 := hash;
		v1 := hash;
		v2 := hash;
		v3 := hash;
		#
		# The loop that hashes every block: le64 and rotr written out,
		# since a Dis call costs more than the arithmetic (this took
		# half of gefs's time writing, at 12 calls a word), and the
		# words put together from 32-bit halves, cheaper than 64.
		#
		m32 := big 16rFFFFFFFF;
		r29 := big 16r7FFFFFFFF;	# a logical >> 29 keeps 35 bits
		do{
			lo := int key[p] | (int key[p+1]<<8) | (int key[p+2]<<16) | (int key[p+3]<<24);
			hi := int key[p+4] | (int key[p+5]<<8) | (int key[p+6]<<16) | (int key[p+7]<<24);
			v0 += ((big hi << 32) | (big lo & m32)) * k0;
			v0 = (((v0 >> 29) & r29) | (v0 << 35)) + v2;
			lo = int key[p+8] | (int key[p+9]<<8) | (int key[p+10]<<16) | (int key[p+11]<<24);
			hi = int key[p+12] | (int key[p+13]<<8) | (int key[p+14]<<16) | (int key[p+15]<<24);
			v1 += ((big hi << 32) | (big lo & m32)) * k1;
			v1 = (((v1 >> 29) & r29) | (v1 << 35)) + v3;
			lo = int key[p+16] | (int key[p+17]<<8) | (int key[p+18]<<16) | (int key[p+19]<<24);
			hi = int key[p+20] | (int key[p+21]<<8) | (int key[p+22]<<16) | (int key[p+23]<<24);
			v2 += ((big hi << 32) | (big lo & m32)) * k2;
			v2 = (((v2 >> 29) & r29) | (v2 << 35)) + v0;
			lo = int key[p+24] | (int key[p+25]<<8) | (int key[p+26]<<16) | (int key[p+27]<<24);
			hi = int key[p+28] | (int key[p+29]<<8) | (int key[p+30]<<16) | (int key[p+31]<<24);
			v3 += ((big hi << 32) | (big lo & m32)) * k3;
			v3 = (((v3 >> 29) & r29) | (v3 << 35)) + v1;
			p += 32;
		}while(p <= n-32);
		t := ((v0 + v3) * k0) + v1; v2 ^= rotr(t, 33) * k1;
		t = ((v1 + v2) * k1) + v0; v3 ^= rotr(t, 33) * k0;
		t = ((v0 + v2) * k0) + v3; v0 ^= rotr(t, 33) * k1;
		t = ((v1 + v3) * k1) + v2; v1 ^= rotr(t, 33) * k0;
		hash += v0 ^ v1;
	}
	if(n - p >= 16){
		v0 := hash + (le64(key, p) * k0); p += 8; v0 = rotr(v0, 33) * k1;
		v1 := hash + (le64(key, p) * k1); p += 8; v1 = rotr(v1, 33) * k2;
		t := v0 * k0; v0 ^= rotr(t, 35) + v1;
		t = v1 * k3; v1 ^= rotr(t, 35) + v0;
		hash += v1;
	}
	if(n - p >= 8){
		hash += le64(key, p) * k3; p += 8;
		hash ^= rotr(hash, 33) * k1;
	}
	#
	# The tails are 32-bit products, as C's promotions make them: an
	# unsigned 32-bit word times an int constant is unsigned (zero-
	# extended into the sum), and a 16- or 8-bit one is promoted to int,
	# so its product is signed (sign-extended). Blocks, logs and the
	# superblock are multiples of 8, so the disk never meets these
	# tails; they are kept exact anyway.
	#
	t32 := big 16rFFFFFFFF;
	if(n - p >= 4){
		hash += (le32(key, p) * k3) & t32; p += 4;
		hash ^= rotr(hash, 15) * k1;
	}
	if(n - p >= 2){
		hash += big int (le16(key, p) * k3); p += 2;
		hash ^= rotr(hash, 13) * k1;
	}
	if(n - p >= 1){
		hash += big int (big key[p] * k3);
		hash ^= rotr(hash, 25) * k1;
	}
	hash ^= rotr(hash, 33);
	hash *= k0;
	hash ^= rotr(hash, 33);
	return hash;
}

bufhash(b: array of byte, n: int): big
{
	return metrohash64(b, n, 16r6765);
}

blkhash(b: ref Blk): big
{
	return metrohash64(b.buf, Blksz, 16r6765);
}

# a 32-bit hash of a 64-bit value, for tables
ihash(x: big): int
{
	x = (x ^ lsr(x, 30)) * (big 16r3f58476d1ce4e5b9 | (big 1<<63));
	x = (x ^ lsr(x, 27)) * (big 16r14d049bb133111eb | (big 1<<63));
	x = x ^ lsr(x, 31);
	return int x;
}
