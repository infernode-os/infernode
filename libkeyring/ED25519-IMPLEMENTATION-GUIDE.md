# Ed25519 Implementation Guide for Inferno

This document captures lessons learned from implementing and debugging Ed25519 in Inferno/infernode. It serves as a reference for future cryptographic work.

## Overview

Ed25519 is a high-speed, high-security signature scheme using elliptic curves. This implementation follows RFC 8032 and integrates with Inferno's existing `keyring` module infrastructure.

## Architecture

### File Structure

```
libkeyring/
├── ed25519alg.c          # Ed25519 implementation (new)
├── ED25519-IMPLEMENTATION-GUIDE.md  # This file
├── dsaalg.c              # DSA (existing)
├── egalg.c               # ElGamal (existing)
├── rsaalg.c              # RSA (existing)
├── mldsaalg.c            # ML-DSA-65/87 (FIPS 204)
├── slhdsaalg.c           # SLH-DSA (FIPS 205)
├── keys.h                # SigAlgVec interface
├── NOTICE
└── mkfile                # Build configuration

libinterp/
└── keyring.c             # Algorithm registration
```

### SigAlgVec Interface

All signature algorithms in Inferno implement the `SigAlgVec` interface defined in `keys.h`:

```c
struct SigAlgVec {
    char *name;           // Algorithm name ("ed25519")
    char **skattr;        // Secret key attributes
    char **pkattr;        // Public key attributes
    char **sigattr;       // Signature attributes

    // Serialization
    void* (*str2sk)(char*, char**);
    void* (*str2pk)(char*, char**);
    void* (*str2sig)(char*, char**);
    int (*sk2str)(void*, char*, int);
    int (*pk2str)(void*, char*, int);
    int (*sig2str)(void*, char*, int);

    // Key operations
    void* (*sk2pk)(void*);        // Derive PK from SK
    void* (*gensk)(int);          // Generate keypair
    void* (*genskfrompk)(void*);  // N/A for Ed25519

    // Sign/Verify
    void* (*sign)(mpint*, void*);      // Sign hash
    int (*verify)(mpint*, void*, void*); // Verify signature

    // Memory management
    void (*skfree)(void*);
    void (*pkfree)(void*);
    void (*sigfree)(void*);
};
```

## Implementation Details

### Key Representation

Ed25519 keys are fixed-size:
- **Secret key**: 64 bytes (32-byte seed + 32-byte public key)
- **Public key**: 32 bytes
- **Signature**: 64 bytes (32-byte R + 32-byte S)

### Field Elements

Field elements are represented as 10 limbs with alternating 26/25-bit radix (ref10 style):

```c
typedef int32_t fe[10];
// Limb 0, 2, 4, 6, 8: 26 bits
// Limb 1, 3, 5, 7, 9: 25 bits
```

### Critical Constants

The base point B and curve constant d must use **non-negative limb values**:

```c
// CORRECT - non-negative limbs
static const fe Bx = {
    50427375, 25998690, 16144682, 17082669, 27570973,
    30858332, 40966398, 8378388, 20764389, 8758491
};

// WRONG - negative limbs (fe_reduce doesn't handle these)
static const fe Bx = {
    -14297830, -7645148, 16144680, -8031792, 27570974, ...
};
```

### Scalar Multiply-Add

The signature scalar S is computed as: `S = (h * s + r) mod L`

Where:
- `h` = SHA-512(R || pk || message) reduced mod L
- `s` = clamped secret scalar
- `r` = nonce scalar
- `L` = group order (2^252 + 27742317777372353535851937790883648493)

**Critical: Use mpint for correctness**

The inline ref10-style muladd has subtle bugs. Use mpint:

```c
static void
sc_muladd_simple(uchar *s, const uchar *a, const uchar *b, const uchar *c)
{
    // Convert little-endian to big-endian mpint
    // Compute (a * b + c) mod L using mpint
    // Convert back to little-endian
}
```

## Debugging Lessons Learned

### 1. Verify Constants First

**Problem**: Base point Bx/By had wrong limb values.

**Symptom**: `[1]B` encoded incorrectly.

**Solution**: Verify `fe_tobytes(By)` produces `5866666666...` (the canonical encoding).

### 2. Test Components Independently

Add self-tests that run on first use:

```c
static void
ed25519_selftest(void)
{
    // Test [1]B = B
    // Test [0]B = identity
    // Test [2]B via scalar mult = [2]B via doubling
    // Test SHA512 with known vectors
    // Test RFC 8032 keygen
    // Test RFC 8032 verify
}
```

### 3. Scalar Operations Are Tricky

**Problem**: Inline `sc_muladd` produced wrong S values.

**Symptom**:
- Sign appeared to work
- Verify always failed
- Self-verify in sign function failed

**Debugging approach**:
1. Add `[S]B == [r]B + [h*s]B` verification in sign
2. Extract r, s, h, S values
3. Verify with Python: `(h * s + r) % L`
4. Discovered mismatch

**Solution**: Replace inline muladd with mpint-based version.

### 4. Verify Before Signing

Add self-verification in the sign function:

```c
// After computing signature, verify it
ge_scalarmult_base(&SB, sig + 32);
// SB should equal R + hA
```

### 5. Little-Endian vs Big-Endian

Ed25519 uses **little-endian** throughout. Inferno's mpint uses **big-endian**.

```c
// Convert little-endian to big-endian for mpint
for(i = 0; i < 32; i++)
    rev[i] = le_bytes[31-i];
ma = betomp(rev, 32, nil);

// Convert big-endian mpint back to little-endian
mptobe(m, be_bytes, 32, nil);
for(i = 0; i < 32; i++)
    le_bytes[i] = be_bytes[31-i];
```

## Testing

### RFC 8032 Test Vector 1

```
SECRET KEY: 9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60
PUBLIC KEY: d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a
MESSAGE:    (empty)
SIGNATURE:  e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b
```

### Python Verification Script

```python
#!/usr/bin/env python3
"""Verify Ed25519 scalar muladd: S = h*s + r mod L"""

L = 2**252 + 27742317777372353535851937790883648493

def hex_to_scalar(hex_str):
    """Convert hex string (little-endian) to integer"""
    return int.from_bytes(bytes.fromhex(hex_str), 'little')

# Values from debug output
r = hex_to_scalar(r_hex)
s = hex_to_scalar(s_hex)
h = hex_to_scalar(h_hex)
S_computed = (h * s + r) % L

# Compare with actual
S_computed_hex = S_computed.to_bytes(32, 'little').hex()
print(f"Match: {S_computed_hex == S_actual}")
```

## Build Instructions

```bash
cd /path/to/infernode
export ROOT=$(pwd)
export SYSHOST=MacOSX
export OBJTYPE=arm64
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"

# Build library
cd libkeyring && mk

# Build emulator
cd .. && ./build-macos-sdl3.sh

# Run tests
./emu/MacOSX/o.emu -r. /tests/crypto_test.dis -v
```

## Performance Notes

The `sc_muladd_simple()` function using mpint is slower than an optimized inline version. For production, consider:

1. Debugging the inline ref10-style muladd
2. Using TweetNaCl's simpler implementation
3. Keeping mpint version (correctness > speed for crypto)

## References

- [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html) - EdDSA specification
- [TweetNaCl](https://tweetnacl.cr.yp.to/) - Compact reference implementation
- [SUPERCOP ref10](https://github.com/floodyberry/supercop/tree/master/crypto_sign/ed25519/ref10) - Original ref10
- [ed25519-donna](https://github.com/floodyberry/ed25519-donna) - Optimized implementation

## Changelog

- **2026-01-29**: Initial implementation, fixed scalar muladd bug
- **2026-01-30**: Added comprehensive documentation and lessons learned
