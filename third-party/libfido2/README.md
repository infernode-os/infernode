# libfido2 (vendored)

Vendored libfido2 + transitive dependencies for FIDO2 / YubiKey support
behind the `#F` (/dev/2fa) device in `emu/port/devtfa.c`. The emu
host-side bridge (`emu/<platform>/fido2bridge.c`) calls into libfido2
when `HAVE_FIDO2` is defined at compile time; otherwise it falls back
to stubs that return "not supported".

## What's here

| Platform | Source | Files |
| --- | --- | --- |
| `win-amd64/` | [Yubico libfido2 1.17.0 Windows release][yubico-releases] | `fido2.dll` + cbor/crypto/zlib DLLs + headers + import libs |

(macOS and Linux still install libfido2 via the host package manager
during release builds — see `.github/workflows/release.yml`. They
will move to the same vendored model in a follow-up so all three
platforms have one canonical source of truth.)

## Licenses

The vendored bundles include code under several licenses, all
permissive and compatible with InferNode's MIT licence:

- `fido2.dll`, `fido2.lib`, `include/fido/*` — BSD-2-Clause
  (Yubico AB). See `win-amd64/LICENSE-libfido2`.
- `cbor.dll`, `cbor.lib`, `include/cbor/*` — MIT (libcbor /
  Pavel Kalvoda).
- `crypto-56.dll`, `crypto.lib` — Apache-2.0 (OpenSSL 3.x).
- `zlib1.dll`, `zlib1.lib`, `include/zconf.h`, `include/zlib.h` —
  zlib licence.

A consolidated NOTICE entry for these libraries lives in the
top-level `NOTICE` file (added under the same change that wired the
Windows build to consume these).

## Refreshing

When Yubico publishes a new libfido2 release:

```sh
./third-party/libfido2/refresh.sh    # downloads, verifies, re-stages win-amd64/
git status third-party/libfido2/     # review the binary churn
```

The refresh script verifies the upstream `.sig` against Yubico's
release PGP key before overwriting the staged binaries.

[yubico-releases]: https://developers.yubico.com/libfido2/Releases/
