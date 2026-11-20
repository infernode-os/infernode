#include "os.h"
#include <mp.h>
#include <libsec.h>

/*
 * Raw RSA public-key operation: out = in^ek mod n.
 *
 * WARNING: This is textbook RSA with NO padding (no OAEP, no PKCS#1).
 * It MUST NOT be used for direct encryption of messages.
 *
 * Current usage: RSA signature verification only (rsa_verify in rsaalg.c),
 * where the caller applies PKCS#1 v1.5 digest encoding separately.
 * If you need RSA encryption, use OAEP padding (see pkcs.b).
 */
mpint*
rsaencrypt(RSApub *rsa, mpint *in, mpint *out)
{
	// RFC 8017 5.1.1 and 5.2.2, step 1: a representative is between 0
	// and n-1, or there is no result (nil).  s+n and s-n verified as s.
	if(in->sign < 0 || mpcmp(in, rsa->n) >= 0){
		werrstr("rsaencrypt: representative out of range");
		return nil;
	}
	if(out == nil)
		out = mpnew(0);
	mpexp(in, rsa->ek, rsa->n, out);
	return out;
}
