# Ed25519 Debug Checkpoint

**Date:** 2026-01-29
**Status:** RESOLVED - Ed25519 signing and verification working correctly

## Problem Summary

Ed25519 signature verification was failing. `ed25519_verify()` returned 0 when it should return 1.

## Root Cause

The inline scalar multiply-add (`sc_muladd`) computation in `ed25519_sign()` was producing incorrect results. The ~170-line implementation had bugs in the limb decomposition or reduction that caused the final signature scalar `S` to be computed incorrectly.

**Python verification confirmed:**
- Expected S: `e6c49edf5aecf034...`
- Actual S: `ad40c0f11eeb1f55...`

## Solution

Replaced the broken inline `sc_muladd` with a new `sc_muladd_simple()` function that uses Inferno's `mpint` library for correct arbitrary-precision arithmetic:

```c
/*
 * Scalar multiply-add: s = (a * b + c) mod L
 * Uses mpint for correctness (slower but verified)
 */
static void
sc_muladd_simple(uchar *s, const uchar *a, const uchar *b, const uchar *c)
{
    // Converts little-endian bytes to big-endian mpint
    // Computes (a * b + c) mod L
    // Converts result back to little-endian bytes
}
```

## What Was Fixed

### 1. Base Point Constants (earlier fix)
- **Issue:** Original Bx/By values used incorrect limb format
- **Root Cause:** `fe_reduce` doesn't handle negative limbs properly
- **Fix:** Computed non-negative limb representation

### 2. Curve Constants (earlier fix)
- **Issue:** Constants d, d2, sqrtm1 had wrong values
- **Fix:** Verified against RFC 8032 and TweetNaCl

### 3. Scalar Multiply-Add (this fix)
- **Issue:** Inline 170-line muladd produced wrong results
- **Fix:** Implemented `sc_muladd_simple()` using mpint

## Test Results

All Ed25519 tests now pass:

```
SELFTEST [1]B: match=1
SELFTEST [0]B: identity_enc[0:8] = 0100000000000000 (expected 01000000...)
SELFTEST [2]B: match=1
SELFTEST SHA512: sha512('')[0:8] = cf83e1357eefb8bd (expect cf83e135...)
SELFTEST SHA512: sha512('abc')[0:8] = ddaf35a193617aba (expect ddaf35a1...)
SELFTEST RFC8032: pk_match=1
SELFTEST RFC8032 VERIFY: result=1 (expected 1)
--- PASS: Ed25519/KeyGen
--- PASS: Ed25519/SignVerify
--- PASS: SHA256/Certificates
--- PASS: RSA/2048bit
```

## Files Modified

### `/Users/pdfinn/github.com/NERVsystems/infernode/libkeyring/ed25519alg.c`
- Added `sc_muladd_simple()` function using mpint
- Replaced inline muladd call in `ed25519_sign()` with `sc_muladd_simple()`

### `/Users/pdfinn/github.com/NERVsystems/infernode/tests/crypto_test.b`
- Removed "KNOWN BUG" comments
- Enabled Ed25519 in multi-algorithm test

## Build Process

```bash
# Build library
cd /Users/pdfinn/github.com/NERVsystems/infernode
export ROOT=$(pwd)
export SYSHOST=MacOSX
export OBJTYPE=arm64
export PATH="$ROOT/MacOSX/arm64/bin:$PATH"
cd libkeyring && mk

# Build emulator
cd /Users/pdfinn/github.com/NERVsystems/infernode
./build-macos-sdl3.sh

# Run tests
./emu/MacOSX/o.emu -r. /tests/crypto_test.dis -v
```

## Performance Notes

The `sc_muladd_simple()` function using mpint is slower than a properly optimized inline implementation. For production use, the inline muladd should be debugged and fixed. However, correctness is more important than performance for cryptographic operations.

## Reference Implementations Consulted

- [RFC 8032](https://www.rfc-editor.org/rfc/rfc8032.html) - EdDSA specification
- [orlp/ed25519](https://github.com/orlp/ed25519) - Portable C implementation
- [SUPERCOP ref10](https://github.com/floodyberry/supercop/blob/master/crypto_sign/ed25519/ref10/) - Reference implementation
- [TweetNaCl](https://tweetnacl.cr.yp.to/) - Compact implementation

## Future Work

- Debug and fix the inline `sc_muladd` for better performance
- Clean up debug output from ed25519alg.c
- Consider using TweetNaCl's simpler implementation as reference
