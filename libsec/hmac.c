#include "os.h"
#include <libsec.h>

/*
 * rfc2104
 *
 * Where a digest is wanted nothing is allocated: the outer hash's state,
 * the hash of a key longer than a block, and the inner state of a call
 * given none, are this function's own.  They were malloc'd by the
 * digest, and nil is both its "no memory" and its "done": with no
 * memory for the outer state the digest was never written and nil
 * came back as it does for success (devssl compared a record's MAC with
 * an unwritten buffer; its GCM key was taken from one); with none for
 * a long key's hash the key was whatever the stack held.  Only a
 * message begun with no state and no digest wanted still allocates,
 * and nil then says so.  The pads and digests, which are the key's
 * equal, are cleared.
 */
static DigestState*
hmac_x(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s,
	DigestState*(*x)(uchar*, ulong, uchar*, DigestState*), int xlen, int bsize)
{
	int i;
	uchar pad[Digestbsize+1], innerdigest[SHA512dlen];
	uchar keydigest[SHA512dlen];
	DigestState inner, outer;

	if(xlen > sizeof(innerdigest))
		return nil;
	if(bsize > Digestbsize)
		return nil;

	/* per RFC 2104: if key longer than block size, hash it first */
	if(klen > bsize){
		memset(keydigest, 0, sizeof(keydigest));
		(*x)(key, klen, keydigest, nil);
		key = keydigest;
		klen = xlen;
	}

	if(s == nil && digest != nil){
		memset(&inner, 0, sizeof(inner));
		s = &inner;
	}

	/* first time through */
	if(s == nil || s->seeded == 0){
		memset(pad, 0x36, bsize);
		pad[bsize] = 0;
		for(i=0; i<klen; i++)
			pad[i] ^= key[i];
		s = (*x)(pad, bsize, nil, s);
		if(s == nil){
			secureZero(pad, sizeof(pad));
			secureZero(keydigest, sizeof(keydigest));
			return nil;
		}
	}

	s = (*x)(p, len, nil, s);
	if(digest == nil){
		secureZero(pad, sizeof(pad));
		secureZero(keydigest, sizeof(keydigest));
		return s;
	}

	/* last time through */
	memset(pad, 0x5c, bsize);
	pad[bsize] = 0;
	for(i=0; i<klen; i++)
		pad[i] ^= key[i];
	(*x)(nil, 0, innerdigest, s);
	memset(&outer, 0, sizeof(outer));
	(*x)(pad, bsize, nil, &outer);
	(*x)(innerdigest, xlen, digest, &outer);
	secureZero(pad, sizeof(pad));
	secureZero(keydigest, sizeof(keydigest));
	secureZero(innerdigest, sizeof(innerdigest));
	secureZero(&inner, sizeof(inner));
	secureZero(&outer, sizeof(outer));
	return nil;
}

DigestState*
hmac_sha1(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	return hmac_x(p, len, key, klen, digest, s, sha1, SHA1dlen, SHA256bsize);
}

DigestState*
hmac_md5(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	return hmac_x(p, len, key, klen, digest, s, md5, MD5dlen, SHA256bsize);
}

DigestState*
hmac_sha256(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	return hmac_x(p, len, key, klen, digest, s, sha256, SHA256dlen, SHA256bsize);
}

DigestState*
hmac_sha384(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	return hmac_x(p, len, key, klen, digest, s, sha384, SHA384dlen, SHA512bsize);
}

DigestState*
hmac_sha512(uchar *p, ulong len, uchar *key, ulong klen, uchar *digest, DigestState *s)
{
	return hmac_x(p, len, key, klen, digest, s, sha512, SHA512dlen, SHA512bsize);
}
