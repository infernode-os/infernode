# Security Policy

## Supported Versions

| Version | Security fixes |
|---------|----------------|
| The latest release | Yes |
| The release before it | Until 6 months after the latest release came out |
| Older releases | No |
| `master` | Yes, as it is fixed |

This covers every package a release ships: the macOS, Linux and Windows
packages and the Raspberry Pi 3B+ and 4B card images.

A security fix ships as a new release, on the
[releases page](https://github.com/infernode-os/infernode/releases), signed
(sigstore) and with build provenance. Nothing updates itself: you install the
new release as you installed the old one. On a Raspberry Pi that means writing
the new card image, which replaces the whole card, `usr/` too (your keys and
secstore account): copy `usr/` off first and back after. A release that fixes a
security problem says so in its notes, with the advisory.

## Reporting a Vulnerability

If you discover a security vulnerability in InferNode, please report it
responsibly:

1. **Do not** open a public GitHub issue for security vulnerabilities.
2. Email security details to the maintainers via GitHub private vulnerability
   reporting: https://github.com/infernode-os/infernode/security/advisories/new
3. Include a description of the vulnerability, steps to reproduce, and any
   relevant proof-of-concept code.

You should receive an acknowledgement within 72 hours. We will work with you
to understand the issue and coordinate a fix before any public disclosure.

## Scope

The following components are in scope for security reports:

- **Dis VM interpreter and JIT compiler** (`libinterp/`)
- **Emulator kernel** (`emu/port/`, `emu/MacOSX/`, `emu/Linux/`, `emu/Nt/`)
- **Bare-metal kernel** (`os/`)
- **Cryptography** (`libsec/`, `libmp/`, `libkeyring/`)
- **9P protocol implementation** (`emu/port/devmnt.c`, `emu/port/exportfs.c`)
- **Namespace and capability system** (`emu/port/pgrp.c`, `emu/port/devcap.c`)

## Security Measures

- Static analysis via CodeQL, cppcheck, and flawfinder runs on every push
- All GitHub Actions are pinned to specific commit SHAs
- Workflow tokens follow the principle of least privilege
