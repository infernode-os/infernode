/*
 * NIST's ACVP vectors for ML-KEM (FIPS 203), ML-DSA (FIPS 204) and
 * SLH-DSA (FIPS 205) against libsec, built by tests/host/acvp_pq_test.sh
 * with the library's sources.  The cases are lines on standard input,
 * made from NIST's JSON files by reduce.py:
 *
 *	KIND tg=N tc=N set=N name=hex ...
 *
 *   mlkem-keygen	d z -> eksum dksum	ML-KEM.KeyGen with d and z from the
 *					generator (FIPS 203 Algorithm 19's)
 *   mlkem-encap	ek m -> csum k		ML-KEM.Encaps with m from the generator
 *   mlkem-decap	dk c -> k		ML-KEM.Decaps (a modified ciphertext
 *					gives the implicit rejection's key)
 *   mlkem-ekcheck	ek -> pass		the input check of section 7.2
 *   mlkem-dkcheck	dk -> pass		and of section 7.3
 *   mldsa-keygen	seed -> pksum sksum	ML-DSA.KeyGen_internal
 *   mldsa-siggen	iface sk msg ismu ctx rnd -> sigsum
 *		iface=ext: ML-DSA.Sign(sk, msg, ctx) with rnd from the
 *		generator, through mldsa65_sign_ctx and mldsa87_sign_ctx
 *		(rnd of zeros is the standard's deterministic variant)
 *		iface=int: ML-DSA.Sign_internal(sk, msg, rnd), or with
 *		ismu=1 with msg as mu
 *   mldsa-sigver	iface pk msg ismu ctx sig -> pass
 *   slh-keygen	skseed skprf pkseed -> pk sk	slh_keygen_internal
 *   slh-siggen	iface sk msg ctx addrnd -> sigsum
 *		iface=ext: slh_sign(msg, ctx, sk) with addrnd from the
 *		generator, through the _sign_ctx functions; addrnd "-" is
 *		the deterministic variant, opt_rand = PK.seed, which the
 *		hedged functions make when the generator gives PK.seed
 *		iface=int: slh_sign_internal(msg, sk, addrnd)
 *   slh-sigver	iface pk msg ctx sig -> pass
 *
 * "sum" is the SHAKE256-256 of the value.  Every case is checked and
 * counted; -v prints each, and a failure always.  The exit status is
 * whether all passed.
 */
#include "os.h"
#include <libsec.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

/* genrandom: the bytes a case queued, and nothing else: a case that asks for more is wrong */
static uchar rngq[256];
static int rngqn, rngqp, rngshort;

void
genrandom(uchar *p, int n)
{
	if(rngqp + n > rngqn){
		rngshort = 1;
		memset(p, 0, n);
		return;
	}
	memmove(p, rngq + rngqp, n);
	rngqp += n;
}

static void
queue(const uchar *a, int na, const uchar *b, int nb)
{
	if(na + nb > sizeof rngq)
		abort();
	memmove(rngq, a, na);
	if(nb > 0)
		memmove(rngq + na, b, nb);
	rngqn = na + nb;
	rngqp = 0;
	rngshort = 0;
}

/* the generator gave exactly what was queued */
static int
drained(void)
{
	int ok;

	ok = rngqp == rngqn && !rngshort;
	rngqn = rngqp = 0;
	return ok;
}

enum { Maxf = 16 };
static char *fname[Maxf], *fval[Maxf];
static int nfield;

static char*
field(const char *name)
{
	int i;

	for(i = 0; i < nfield; i++)
		if(strcmp(fname[i], name) == 0)
			return fval[i];
	return nil;
}

/* a field's bytes in a buffer exactly their length (the sanitizers see a read past it); nil if absent */
static uchar*
bytes(const char *name, int *np)
{
	char *s;
	uchar *o;
	int n, i;
	unsigned v;

	*np = 0;
	s = field(name);
	if(s == nil)
		return nil;
	if(strcmp(s, "-") == 0)
		s = "";
	n = strlen(s)/2;
	o = malloc(n ? n : 1);
	if(o == nil)
		abort();
	for(i = 0; i < n; i++){
		if(sscanf(s + 2*i, "%2x", &v) != 1){
			free(o);
			return nil;
		}
		o[i] = v;
	}
	*np = n;
	return o;
}

static int
num(const char *name)
{
	char *s;

	s = field(name);
	return s == nil ? -1 : atoi(s);
}

static int
sumis(const uchar *p, int n, const char *name)
{
	uchar sum[32], *want;
	int nw, ok;

	want = bytes(name, &nw);
	shake256(p, n, sum, 32);
	ok = want != nil && nw == 32 && memcmp(sum, want, 32) == 0;
	free(want);
	return ok;
}

static int
is(const uchar *p, int n, const char *name)
{
	uchar *want;
	int nw, ok;

	want = bytes(name, &nw);
	ok = want != nil && nw == n && memcmp(p, want, n) == 0;
	free(want);
	return ok;
}

/* M' of the external interface: 0 || |ctx| || ctx || M */
static uchar*
mprime(const uchar *msg, int n, const uchar *ctx, int nctx, int *np)
{
	uchar *m;

	m = malloc(2 + nctx + n);
	m[0] = 0;
	m[1] = nctx;
	memmove(m + 2, ctx, nctx);
	memmove(m + 2 + nctx, msg, n);
	*np = 2 + nctx + n;
	return m;
}

/* each returns 1 if the case passed, 0 if not, -1 if the line is not understood */

static int
mlkem(const char *kind, int set)
{
	int pklen, sklen, ctlen, n1, n2, n3, ok, rc, want;
	uchar *a, *b, *c, *pk, *sk, *ct, ss[32];

	if(set == 768){
		pklen = MLKEM768_PKLEN; sklen = MLKEM768_SKLEN; ctlen = MLKEM768_CTLEN;
	}else if(set == 1024){
		pklen = MLKEM1024_PKLEN; sklen = MLKEM1024_SKLEN; ctlen = MLKEM1024_CTLEN;
	}else
		return -1;
	ok = -1;
	if(strcmp(kind, "mlkem-keygen") == 0){
		a = bytes("d", &n1);
		b = bytes("z", &n2);
		if(a == nil || b == nil || n1 != 32 || n2 != 32)
			return -1;
		pk = malloc(pklen);
		sk = malloc(sklen);
		queue(a, 32, b, 32);
		rc = set == 768 ? mlkem768_keygen(pk, sk) : mlkem1024_keygen(pk, sk);
		ok = rc == 0 && drained() && sumis(pk, pklen, "eksum") && sumis(sk, sklen, "dksum");
		free(a); free(b); free(pk); free(sk);
	}else if(strcmp(kind, "mlkem-encap") == 0){
		a = bytes("ek", &n1);
		b = bytes("m", &n2);
		if(a == nil || b == nil || n1 != pklen || n2 != 32)
			return -1;
		ct = malloc(ctlen);
		queue(b, 32, nil, 0);
		rc = set == 768 ? mlkem768_encaps(ct, ss, a) : mlkem1024_encaps(ct, ss, a);
		ok = rc == 0 && drained() && sumis(ct, ctlen, "csum") && is(ss, 32, "k");
		free(a); free(b); free(ct);
	}else if(strcmp(kind, "mlkem-decap") == 0){
		a = bytes("dk", &n1);
		c = bytes("c", &n3);
		if(a == nil || c == nil || n1 != sklen || n3 != ctlen)
			return -1;
		rc = set == 768 ? mlkem768_decaps(ss, c, a) : mlkem1024_decaps(ss, c, a);
		ok = rc == 0 && is(ss, 32, "k");
		free(a); free(c);
	}else if(strcmp(kind, "mlkem-ekcheck") == 0){
		a = bytes("ek", &n1);
		want = num("pass");
		if(a == nil || want < 0)
			return -1;
		/* a key of another length is no key; the functions take the length for granted */
		rc = n1 != pklen ? -1 : set == 768 ? mlkem768_checkek(a) : mlkem1024_checkek(a);
		ok = (rc == 0) == want;
		free(a);
	}else if(strcmp(kind, "mlkem-dkcheck") == 0){
		a = bytes("dk", &n1);
		want = num("pass");
		if(a == nil || want < 0)
			return -1;
		rc = n1 != sklen ? -1 : set == 768 ? mlkem768_checkdk(a) : mlkem1024_checkdk(a);
		ok = (rc == 0) == want;
		free(a);
	}
	return ok;
}

static int
mldsa(const char *kind, int set)
{
	int pklen, sklen, siglen, n1, n2, n3, n4, n5, ok, rc, want, ext, ismu;
	uchar *a, *msg, *ctx, *rnd, *sig, *pk, *sk, *mine;
	char *iface;

	if(set == 65){
		pklen = MLDSA65_PKLEN; sklen = MLDSA65_SKLEN; siglen = MLDSA65_SIGLEN;
	}else if(set == 87){
		pklen = MLDSA87_PKLEN; sklen = MLDSA87_SKLEN; siglen = MLDSA87_SIGLEN;
	}else
		return -1;
	if(strcmp(kind, "mldsa-keygen") == 0){
		a = bytes("seed", &n1);
		if(a == nil || n1 != 32)
			return -1;
		pk = malloc(pklen);
		sk = malloc(sklen);
		rc = mldsa_keygen_internal(set, pk, sk, a);
		ok = rc == 0 && sumis(pk, pklen, "pksum") && sumis(sk, sklen, "sksum");
		/* and through the generator, as ML-DSA.KeyGen draws the seed */
		queue(a, 32, nil, 0);
		rc = set == 65 ? mldsa65_keygen(pk, sk) : mldsa87_keygen(pk, sk);
		ok = ok && rc == 0 && drained() && sumis(pk, pklen, "pksum") && sumis(sk, sklen, "sksum");
		free(a); free(pk); free(sk);
		return ok;
	}
	iface = field("iface");
	ismu = num("ismu");
	if(iface == nil || ismu < 0)
		return -1;
	ext = strcmp(iface, "ext") == 0;
	msg = bytes("msg", &n2);
	ctx = bytes("ctx", &n3);
	if(msg == nil || ctx == nil || (ismu && n2 != 64) || (ext && ismu))
		return -1;
	ok = -1;
	if(strcmp(kind, "mldsa-siggen") == 0){
		sk = bytes("sk", &n1);
		rnd = bytes("rnd", &n4);
		if(sk == nil || rnd == nil || n1 != sklen || n4 != 32)
			return -1;
		mine = malloc(siglen);
		memset(mine, 0, siglen);
		if(ext){
			queue(rnd, 32, nil, 0);
			rc = set == 65 ? mldsa65_sign_ctx(mine, msg, n2, ctx, n3, sk) : mldsa87_sign_ctx(mine, msg, n2, ctx, n3, sk);
			ok = rc == 0 && drained() && sumis(mine, siglen, "sigsum");
			if(n3 == 0){
				/* and the plain functions, which are the same with no context */
				queue(rnd, 32, nil, 0);
				rc = set == 65 ? mldsa65_sign(mine, msg, n2, sk) : mldsa87_sign(mine, msg, n2, sk);
				ok = ok && rc == 0 && drained() && sumis(mine, siglen, "sigsum");
			}
		}else{
			if(ismu)
				rc = mldsa_sign_internal(set, mine, nil, 0, msg, rnd, sk);
			else
				rc = mldsa_sign_internal(set, mine, msg, n2, nil, rnd, sk);
			ok = rc == 0 && sumis(mine, siglen, "sigsum");
		}
		free(sk); free(rnd); free(mine);
	}else if(strcmp(kind, "mldsa-sigver") == 0){
		pk = bytes("pk", &n1);
		sig = bytes("sig", &n5);
		want = num("pass");
		if(pk == nil || sig == nil || n1 != pklen || want < 0)
			return -1;
		/* a signature of another length is none; the functions take the length for granted */
		if(n5 != siglen)
			rc = 0;
		else if(ext){
			rc = set == 65 ? mldsa65_verify_ctx(sig, msg, n2, ctx, n3, pk) : mldsa87_verify_ctx(sig, msg, n2, ctx, n3, pk);
			if(n3 == 0 && rc != (set == 65 ? mldsa65_verify(sig, msg, n2, pk) : mldsa87_verify(sig, msg, n2, pk)))
				rc = -1;
		}else if(ismu)
			rc = mldsa_verify_internal(set, sig, nil, 0, msg, pk);
		else
			rc = mldsa_verify_internal(set, sig, msg, n2, nil, pk);
		ok = rc == want;
		free(pk); free(sig);
	}
	free(msg); free(ctx);
	return ok;
}

static int detdone[2];

static int
slh(const char *kind, int set)
{
	int n, pklen, sklen, siglen, n1, n2, n3, n4, n5, ok, rc, want, ext, nmp;
	uchar *a, *b, *c, *msg, *ctx, *rnd, *sig, *pk, *sk, *mine, *mp;
	char *iface;

	if(set == 192){
		n = 24; pklen = SLHDSA192S_PKLEN; sklen = SLHDSA192S_SKLEN; siglen = SLHDSA192S_SIGLEN;
	}else if(set == 256){
		n = 32; pklen = SLHDSA256S_PKLEN; sklen = SLHDSA256S_SKLEN; siglen = SLHDSA256S_SIGLEN;
	}else
		return -1;
	if(strcmp(kind, "slh-keygen") == 0){
		a = bytes("skseed", &n1);
		b = bytes("skprf", &n2);
		c = bytes("pkseed", &n3);
		if(a == nil || b == nil || c == nil || n1 != n || n2 != n || n3 != n)
			return -1;
		pk = malloc(pklen);
		sk = malloc(sklen);
		rc = slhdsa_keygen_internal(set, pk, sk, a, b, c);
		ok = rc == 0 && is(pk, pklen, "pk") && is(sk, sklen, "sk");
		/* and through the generator: SK.seed, SK.prf, PK.seed in that order */
		memmove(rngq, a, n); memmove(rngq + n, b, n); memmove(rngq + 2*n, c, n);
		rngqn = 3*n; rngqp = 0; rngshort = 0;
		rc = set == 192 ? slhdsa192s_keygen(pk, sk) : slhdsa256s_keygen(pk, sk);
		ok = ok && rc == 0 && drained() && is(pk, pklen, "pk") && is(sk, sklen, "sk");
		free(a); free(b); free(c); free(pk); free(sk);
		return ok;
	}
	iface = field("iface");
	if(iface == nil)
		return -1;
	ext = strcmp(iface, "ext") == 0;
	msg = bytes("msg", &n2);
	ctx = bytes("ctx", &n3);
	if(msg == nil || ctx == nil)
		return -1;
	ok = -1;
	if(strcmp(kind, "slh-siggen") == 0){
		sk = bytes("sk", &n1);
		rnd = bytes("addrnd", &n4);
		if(sk == nil || rnd == nil || n1 != sklen || (n4 != n && n4 != 0))
			return -1;
		mine = malloc(siglen);
		memset(mine, 0, siglen);
		if(ext){
			/* the hedged functions; with PK.seed as the randomness they make the deterministic signature */
			if(n4 == 0)
				queue(sk + 2*n, n, nil, 0);
			else
				queue(rnd, n, nil, 0);
			rc = set == 192 ? slhdsa192s_sign_ctx(mine, msg, n2, ctx, n3, sk) : slhdsa256s_sign_ctx(mine, msg, n2, ctx, n3, sk);
			ok = rc == 0 && drained() && sumis(mine, siglen, "sigsum");
			if(n4 == 0 && !detdone[set == 256]){
				/* and, once a set (a signature is a second), slh_sign_internal on M' with no randomness added */
				detdone[set == 256] = 1;
				mp = mprime(msg, n2, ctx, n3, &nmp);
				rc = slhdsa_sign_internal(set, mine, mp, nmp, nil, sk);
				ok = ok && rc == 0 && sumis(mine, siglen, "sigsum");
				free(mp);
			}
		}else{
			rc = slhdsa_sign_internal(set, mine, msg, n2, n4 == 0 ? nil : rnd, sk);
			ok = rc == 0 && sumis(mine, siglen, "sigsum");
		}
		free(sk); free(rnd); free(mine);
	}else if(strcmp(kind, "slh-sigver") == 0){
		pk = bytes("pk", &n1);
		sig = bytes("sig", &n5);
		want = num("pass");
		if(pk == nil || sig == nil || n1 != pklen || want < 0)
			return -1;
		if(ext){
			rc = set == 192 ? slhdsa192s_verify_ctx(sig, n5, msg, n2, ctx, n3, pk) : slhdsa256s_verify_ctx(sig, n5, msg, n2, ctx, n3, pk);
			if(n3 == 0 && rc != (set == 192 ? slhdsa192s_verify(sig, n5, msg, n2, pk) : slhdsa256s_verify(sig, n5, msg, n2, pk)))
				rc = -1;
		}else
			rc = slhdsa_verify_internal(set, sig, n5, msg, n2, pk);
		ok = rc == want;
		free(pk); free(sig);
	}
	free(msg); free(ctx);
	return ok;
}

int
main(int argc, char **argv)
{
	static char line[400000];
	char *kind, *t, *e, *reason;
	int verbose, lineno, ok, set, total, bad, unknown, i;
	struct { char kind[20]; int n, bad; } tally[16];
	int ntally;

	verbose = argc >= 2 && strcmp(argv[1], "-v") == 0;
	lineno = total = bad = unknown = ntally = 0;
	while(fgets(line, sizeof line, stdin) != nil){
		lineno++;
		if(line[0] == '#' || line[0] == '\n')
			continue;
		if(strchr(line, '\n') == nil){
			fprintf(stderr, "FAIL: line %d is too long\n", lineno);
			return 1;
		}
		kind = strtok(line, " \n");
		nfield = 0;
		while((t = strtok(nil, " \n")) != nil && nfield < Maxf){
			e = strchr(t, '=');
			if(e == nil)
				continue;
			*e = 0;
			fname[nfield] = t;
			fval[nfield] = e + 1;
			nfield++;
		}
		set = num("set");
		if(strncmp(kind, "mlkem-", 6) == 0)
			ok = mlkem(kind, set);
		else if(strncmp(kind, "mldsa-", 6) == 0)
			ok = mldsa(kind, set);
		else if(strncmp(kind, "slh-", 4) == 0)
			ok = slh(kind, set);
		else
			ok = -1;
		reason = field("reason");
		if(ok < 0){
			unknown++;
			fprintf(stderr, "FAIL: line %d not understood: %s tg=%s tc=%s\n", lineno, kind, field("tg"), field("tc"));
			continue;
		}
		total++;
		for(i = 0; i < ntally; i++)
			if(strcmp(tally[i].kind, kind) == 0)
				break;
		if(i == ntally && ntally < 16){
			snprintf(tally[i].kind, sizeof tally[i].kind, "%s", kind);
			tally[i].n = tally[i].bad = 0;
			ntally++;
		}
		tally[i].n++;
		if(!ok){
			bad++;
			tally[i].bad++;
		}
		if(!ok || verbose)
			printf("%s %s set=%d tg=%s tc=%s%s%s\n", ok ? "ok  " : "FAIL", kind, set, field("tg"), field("tc"),
				reason ? " " : "", reason ? reason : "");
	}
	for(i = 0; i < ntally; i++)
		printf("%-14s %3d cases, %d failed\n", tally[i].kind, tally[i].n, tally[i].bad);
	printf("%d cases, %d failed%s\n", total, bad, unknown ? ", and lines not understood" : "");
	return bad != 0 || unknown != 0 || total == 0;
}
