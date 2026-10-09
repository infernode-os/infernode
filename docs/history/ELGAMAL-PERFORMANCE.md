# ElGamal Performance Analysis

## Status: FIXED

ElGamal 2048-bit key generation now uses pre-computed RFC 3526 parameters:
- **Before**: 486,000 ms (8.1 minutes)
- **After**: 2,258 ms (2.3 seconds)
- **Speedup**: 215x

## Original Problem

ElGamal key generation was extremely slow in Inferno/infernode:

| Key Size | Time |
|----------|------|
| 512-bit | 77 seconds |
| 1024-bit | 104 seconds |
| 2048-bit | **486 seconds (8.1 minutes)** |

For comparison:
- Modern systems generate RSA 2048-bit keys in < 1 second
- OpenSSL generates 2048-bit DH parameters in ~10-30 seconds

## Root Cause

ElGamal requires **safe prime** parameters (p where (p-1)/2 is also prime).

### Algorithm (`libsec/gensafeprime.c`):

```c
void gensafeprime(mpint *p, mpint *alpha, int n, int accuracy)
{
    q = mpnew(n-1);
    while(1){
        genprime(q, n-1, accuracy);  // Find a prime q
        p = 2*q + 1;                  // Compute p
        if(probably_prime(p, accuracy))  // Check if p is also prime
            break;                    // If so, we have a safe prime
    }
    // Then find generator alpha...
}
```

### Why It's Slow:

1. **Safe prime probability**: For a random prime q, the probability that 2q+1 is also prime is roughly 1/(ln(n)). For 2048-bit, this means testing ~700+ primes on average.

2. **Primality testing cost**: Each `probably_prime()` call runs 18 Miller-Rabin iterations, each involving modular exponentiation of 2048-bit numbers.

3. **No assembly optimization**: Inferno's `libmp` is pure C without assembly-optimized big integer operations.

4. **Double primality testing**: Each candidate requires TWO primality tests (for q and for p).

### Comparison with RSA

RSA only needs regular primes:
```c
genprime(p, nlen/2, rounds);  // Just one prime
genprime(q, nlen/2, rounds);  // Just one prime
```

This is why RSA 2048-bit keygen completes in seconds while ElGamal takes minutes.

## Solutions

### 1. Use Pre-computed Parameters (Recommended)

Ship with pre-generated safe primes for common sizes. Store in `/lib/crypto/dhparams/`:

```
/lib/crypto/dhparams/dh2048.pem
/lib/crypto/dhparams/dh4096.pem
```

**Security**: Pre-computed parameters are safe as long as:
- They're generated properly (not backdoored)
- Each user generates their own secret exponent

This is what OpenSSL's `DH_get_2048_256()` does.

### 2. Parameter Reuse

Generate parameters once and reuse for multiple keys:

```limbo
# Generate parameters (slow, do once)
params := kr->dhparams(2048);

# Generate keys using those parameters (fast)
sk1 := kr->genSKfromPK(params, "user1");
sk2 := kr->genSKfromPK(params, "user2");
```

The `eg_genfrompk()` function in `egalg.c` already supports this:
```c
static void* eg_genfrompk(void *vpub)
{
    // Uses existing p and alpha, just generates new secret
    mprand(nlen-1, genrandom, priv->secret);
    mpexp(pub->alpha, priv->secret, pub->p, pub->key);
    return priv;
}
```

### 3. Use DSA-style Parameters

DSA uses a different parameter structure that's faster to generate:
- q is a small prime (256 bits)
- p = kq + 1 for some k, where p is a large prime

This is faster because q is small and you're just searching for a p of the form kq+1.

**Tradeoff**: Slightly different security properties.

### 4. Background Generation

Generate parameters in a background thread:

```limbo
spawn generate_dh_params(2048, result_chan);
# ... continue with other work ...
params := <-result_chan;  # Block when needed
```

### 5. Use Ed25519 Instead

For signatures, Ed25519 is:
- **Faster**: Key generation is instant (hash + scalar mult)
- **Smaller**: 32-byte keys vs 256+ bytes
- **Stronger**: 128-bit security with simpler code
- **Deterministic**: No random number needed for signing

**Recommendation**: Use Ed25519 for all new signature applications.

### 6. Optimize libmp (Major Effort)

Add assembly-optimized big integer operations:
- Montgomery multiplication
- Karatsuba multiplication
- Platform-specific assembly (ARM NEON, x86-64)

This could provide 10-50x speedup but requires significant effort.

## Recommendations

1. **Short term**: Use Ed25519 for signatures (already implemented)

2. **Medium term**: Add pre-computed DH parameters for common sizes

3. **Long term**: Consider optimizing libmp or using a faster library

## Profiling Results

Instrumented `gensafeprime.c` to measure where time is actually spent:

**512-bit safe prime generation:**
```
GENSAFEPRIME PROFILE (512 bits):
  Iterations: 553
  genprime() total: 117885 ms (99.7%)
  probably_prime(p) total: 340 ms (0.3%)
  generator search: 1 ms (~0%)
  TOTAL: 118227 ms
```

### Key Finding

**The bottleneck is `genprime()`, NOT `probably_prime(p)`.**

| Phase | Time | Percentage |
|-------|------|------------|
| `genprime(q)` | 117,885 ms | **99.7%** |
| `probably_prime(p)` | 340 ms | 0.3% |
| generator search | 1 ms | ~0% |

- 553 iterations needed (tried 553 primes q before finding safe prime)
- Each `genprime()` call averages ~213 ms
- The `probably_prime(p)` check on p=2q+1 is negligible

### Implications

1. **Combined sieve won't help much** - The issue isn't redundant primality tests on p, it's the expensive Miller-Rabin iterations inside `genprime()` itself.

2. **Pre-computed parameters are the solution** - There's no algorithmic shortcut; Miller-Rabin is inherently expensive in pure C with no assembly-optimized bignum operations.

3. **libmp optimization would help** - Since 99.7% of time is in `genprime()` → `probably_prime()` → Miller-Rabin → modular exponentiation, optimizing `mpexp()` and `mpmod()` would directly improve performance.

## Test Data

Generated on MacOSX/arm64 (Apple Silicon):

```
Generating ElGamal 512-bit key...
  Done in 76806 ms

Generating ElGamal 1024-bit key...
  Done in 103838 ms

Generating ElGamal 2048-bit key...
  Done in 486071 ms
```

## Research Findings (Web Search)

### Combined Sieve Algorithm (Wiener 2003)

[Michael J. Wiener's paper](https://eprint.iacr.org/2003/186) describes a **combined sieve** approach that is "considerably faster than repeatedly generating random primes q until p=2q+1 is also prime."

The key insight: Instead of independently testing random primes q and then checking if 2q+1 is also prime, **simultaneously sieve both q and 2q+1** to eliminate candidates where either has small factors. This dramatically reduces the number of expensive Miller-Rabin tests needed.

### Trial Division Optimization

[Research shows](https://sites.google.com/site/vtsozik/papers/optimization-of-miller-rabin-algorithm-with-sieve-of-eratosthenes-accelerator) that running trial division on approximately **182 small primes** before launching Miller-Rabin minimizes combined complexity. OpenSSL uses the first 2047 odd primes for sieving.

Current Inferno implementation (`libsec/genprime.c`) does have `smallprimetest()` but may not be optimally tuned.

### Standard Pre-computed Groups (Strongly Recommended)

[RFC 3526](https://www.rfc-editor.org/rfc/rfc3526) and [RFC 7919](https://www.rfc-editor.org/rfc/rfc7919) define standard safe prime groups:

| RFC | Group | Size | Generator |
|-----|-------|------|-----------|
| 3526 | MODP Group 14 | 2048-bit | 2 |
| 3526 | MODP Group 15 | 3072-bit | 2 |
| 3526 | MODP Group 16 | 4096-bit | 2 |
| 7919 | ffdhe2048 | 2048-bit | 2 |
| 7919 | ffdhe3072 | 3072-bit | 2 |
| 7919 | ffdhe4096 | 4096-bit | 2 |

These primes were generated using "nothing up my sleeve" numbers (digits of pi or e), making them trustworthy.

**Key quote from research**: "It is not necessary to come up with a group and generator for each new key. Indeed, one may expect a specific implementation of ElGamal to be hardcoded to use a specific group."

### Lim-Lee Primes (Libgcrypt Approach)

[PyCryptodome discussion](https://github.com/Legrandin/pycryptodome/issues/90) notes that Libgcrypt uses **Lim-Lee primes** instead of safe primes:
- Choose small prime q (225 bits for 2048-bit p)
- Find p = kq + 1 that is prime
- Much faster to generate than safe primes
- Still secure against known attacks

## Recommended Implementation Path

1. **Immediate**: Ship RFC 3526/7919 standard parameters in `/lib/crypto/dhparams/`
2. **Short-term**: Implement combined sieve for custom generation
3. **Long-term**: Consider Lim-Lee primes as alternative

## References

- Menezes et al., "Handbook of Applied Cryptography", Algorithm 4.86
- [RFC 3526](https://www.rfc-editor.org/rfc/rfc3526) - MODP Diffie-Hellman groups
- [RFC 7919](https://www.rfc-editor.org/rfc/rfc7919) - Negotiated Finite Field DH Ephemeral Parameters
- [Wiener, "Safe Prime Generation with a Combined Sieve"](https://eprint.iacr.org/2003/186) (2003)
- [OpenSSL DH Parameters Wiki](https://wiki.openssl.org/index.php/Diffie-Hellman_parameters)
- [PyCryptodome ElGamal Discussion](https://github.com/Legrandin/pycryptodome/issues/90)
