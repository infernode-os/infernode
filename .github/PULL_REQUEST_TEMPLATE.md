## Issue

Closes #

<!--
Every pull request needs an issue a maintainer has agreed to, linked
above (typo and broken-link fixes excepted). A pull request without one
will be closed: see CONTRIBUTING.md, "Open an Issue Before a Pull Request".
-->

## Summary

What does this PR do and why?

## Changes

- 

## Testing

How was this tested?

- [ ] Tests pass (`/tests/runner.dis -v`)
- [ ] New tests added (if applicable)
- [ ] Tested on: (platform)

## Checklist

- [ ] Code follows the existing style of the file(s) modified
- [ ] No `.dis` build artifacts committed from `appl/` or `tests/`
- [ ] Documentation updated (if applicable)
- [ ] No secrets, API keys, or credentials included
- [ ] AI tools were used for this PR (if checked, say for what in the Summary; see CONTRIBUTING.md, "AI-Assisted Contributions")

Design principles (see [docs/DESIGN-PRINCIPLES.md](https://github.com/infernode-os/infernode/blob/master/docs/DESIGN-PRINCIPLES.md); check what applies):

- [ ] Composition of existing name spaces, commands and modules was tried first; new code covers only what it measurably could not
- [ ] New code is in Limbo or a host service over 9P, not the kernel or emulator (or the issue says why not)
- [ ] No new third-party dependency, or one agreed with the maintainer in an issue first
- [ ] New capabilities are exposed as file interfaces (9P), not libraries/RPC/bespoke protocols
- [ ] Data crossing 9P interfaces is plain text (no JSON inside the namespace)
- [ ] Access restriction is namespace shape (bind/mount), not policy checks on nameable paths
- [ ] New service/tool followed a namespace-sketch proposal issue (for non-trivial interfaces)
- [ ] Scripts that run inside Inferno are rc-style sh (no `&&`/`||`) and committed executable
- [ ] Irreversible/credentialed actions emit audit records; agent-facing effects have provenance emitters
- [ ] Anything this PR downloads or executes from outside the tree is pinned (commit SHA / revision URL) and checksum-verified
