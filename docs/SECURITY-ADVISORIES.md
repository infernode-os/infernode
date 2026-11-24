# Security advisories

<!-- Written by tools/security-advisories.py index; edit the advisories in
     docs/security-advisories/, not this file. -->

Vulnerabilities fixed in InferNode releases that someone running an
affected release should know about: what was wrong, who could use it,
what the fix changed, and what to do. Each fix was found by the
project's own reviews, red-team campaigns and fuzzing, not reported from
outside; each came with a regression test, and the advisory names the
commits that fixed it.

This is a selection. Every release's **Security** section in
[CHANGELOG.md](../CHANGELOG.md) lists all of its security changes,
including hardening and the many smaller fixes that are not listed
here. An advisory is written for a fix that, on its own, let someone
outside a boundary InferNode claims (the network, a confined agent, a
Limbo program, another user) read, write, run or forge what it should
not.

Only the latest release, and the one before it for six months, gets
fixes ([SECURITY.md](../SECURITY.md)). Releases are not patched in
place: the fix for every advisory below is to install the release that
has it, or a later one. Where an advisory says *unreleased*, the fix is
on `master` and in no release yet.

Each advisory is also filed as a GitHub Security Advisory (GHSA) where
the GHSA column has one; the files here are the record they are made
from. To report a vulnerability, see [SECURITY.md](../SECURITY.md).

| Advisory | Severity | Affected | Fixed in | Summary | GHSA |
|---|---|---|---|---|---|
| [ISA-2026-001](security-advisories/ISA-2026-001.md) | high | `< 0.4.0` | [0.4.0](https://github.com/infernode-os/infernode/releases/tag/v0.4.0) | A confined agent could read and write outside its name space through ".." |  |
| [ISA-2026-002](security-advisories/ISA-2026-002.md) | high | `< 0.4.0` | [0.4.0](https://github.com/infernode-os/infernode/releases/tag/v0.4.0) | Read-only name space views given to agents could be written |  |
| [ISA-2026-003](security-advisories/ISA-2026-003.md) | medium | `< 0.4.1` | [0.4.1](https://github.com/infernode-os/infernode/releases/tag/v0.4.1) | Agent tool workers could read the launcher's environment through "#e" |  |
| [ISA-2026-004](security-advisories/ISA-2026-004.md) | medium | `< 0.4.1` | [0.4.1](https://github.com/infernode-os/infernode/releases/tag/v0.4.1) | A malformed 9P directory entry could be read past its buffer |  |
| [ISA-2026-005](security-advisories/ISA-2026-005.md) | critical | `< 0.5.0` | [0.5.0](https://github.com/infernode-os/infernode/releases/tag/v0.5.0) | The TLS client did not authenticate servers |  |
| [ISA-2026-006](security-advisories/ISA-2026-006.md) | medium | `< 0.6.0` | [0.6.0](https://github.com/infernode-os/infernode/releases/tag/v0.6.0) | Renaming a host file made it world-writable on 64-bit hosts |  |
| [ISA-2026-007](security-advisories/ISA-2026-007.md) | high | `< 0.6.0` | [0.6.0](https://github.com/infernode-os/infernode/releases/tag/v0.6.0) | An agent's native tool call could skip the operator's approval |  |
| [ISA-2026-008](security-advisories/ISA-2026-008.md) | medium | `< 0.6.0` | [0.6.0](https://github.com/infernode-os/infernode/releases/tag/v0.6.0) | ML-DSA signing time depended on the secret key |  |
| [ISA-2026-009](security-advisories/ISA-2026-009.md) | medium | `< 0.8.1` | [0.8.1](https://github.com/infernode-os/infernode/releases/tag/v0.8.1) | A password typed into the browser was readable through its files |  |
| [ISA-2026-010](security-advisories/ISA-2026-010.md) | high | `< 0.9.0` | [0.9.0](https://github.com/infernode-os/infernode/releases/tag/v0.9.0) | Release packages shipped a private key shared by every install |  |
| [ISA-2026-011](security-advisories/ISA-2026-011.md) | high | `< 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | Native kernel IP input trusted lengths that packets claimed |  |
| [ISA-2026-012](security-advisories/ISA-2026-012.md) | critical | `>= 0.2.0, < 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | The voice listener exported all of /dev to the network without authentication |  |
| [ISA-2026-013](security-advisories/ISA-2026-013.md) | high | `< 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | Agent path policy could be bypassed by case, host symlinks and service files |  |
| [ISA-2026-014](security-advisories/ISA-2026-014.md) | high | `< 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | An agent could read and write any file through Xenith |  |
| [ISA-2026-015](security-advisories/ISA-2026-015.md) | high | `< 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | Native kernel made keys from a predictable counter when no hardware generator answered |  |
| [ISA-2026-016](security-advisories/ISA-2026-016.md) | medium | `< 0.10.0` | [0.10.0](https://github.com/infernode-os/infernode/releases/tag/v0.10.0) | Elliptic-curve and modular exponentiation timing depended on secrets |  |
| [ISA-2026-017](security-advisories/ISA-2026-017.md) | medium | `< 0.10.1` | [0.10.1](https://github.com/infernode-os/infernode/releases/tag/v0.10.1) | ssl(3) record protection accepted reflected records and weak MACs |  |
| [ISA-2026-018](security-advisories/ISA-2026-018.md) | low | `< 0.10.1` | [0.10.1](https://github.com/infernode-os/infernode/releases/tag/v0.10.1) | AES-GCM's GHASH used secret-indexed table lookups |  |
| [ISA-2026-019](security-advisories/ISA-2026-019.md) | critical | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | login(6) issued certificates without a password and let passwords be guessed offline |  |
| [ISA-2026-020](security-advisories/ISA-2026-020.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | SLH-DSA signatures could be forged after seeing some signatures from a key |  |
| [ISA-2026-021](security-advisories/ISA-2026-021.md) | critical | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | ElGamal signatures could be forged from the public key alone |  |
| [ISA-2026-022](security-advisories/ISA-2026-022.md) | medium | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | An on-path attacker could downgrade an authenticated connection to clear text |  |
| [ISA-2026-023](security-advisories/ISA-2026-023.md) | critical | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | The signer's names were paths, giving certificates with no approval |  |
| [ISA-2026-024](security-advisories/ISA-2026-024.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | Agent tasks could promote changes anywhere and subagents reach their parent's tools |  |
| [ISA-2026-025](security-advisories/ISA-2026-025.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | The agent's git tool wrote outside the repository for a hostile remote |  |
| [ISA-2026-026](security-advisories/ISA-2026-026.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | A web page could take the browser to local files |  |
| [ISA-2026-027](security-advisories/ISA-2026-027.md) | medium | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | Fetch tools reached loopback services through octal IPv4 addresses |  |
| [ISA-2026-028](security-advisories/ISA-2026-028.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | The wallet paid an address other than the one the approver was shown |  |
| [ISA-2026-029](security-advisories/ISA-2026-029.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | ssl(3) could serve another conversation's data, and a short record crashed it |  |
| [ISA-2026-030](security-advisories/ISA-2026-030.md) | high | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | Limbo programs could corrupt the Dis VM's heap |  |
| [ISA-2026-031](security-advisories/ISA-2026-031.md) | medium | `< 0.11.0` | [0.11.0](https://github.com/infernode-os/infernode/releases/tag/v0.11.0) | Stored cross-site scripting in wikis served by httpd |  |
| [ISA-2026-032](security-advisories/ISA-2026-032.md) | high | `<= 0.12.0` | unreleased | After pctl(NEWNS), a relative ".." left the new root |  |
