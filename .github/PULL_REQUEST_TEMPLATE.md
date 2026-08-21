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

Design principles (see [docs/DESIGN-PRINCIPLES.md](https://github.com/infernode-os/infernode/blob/master/docs/DESIGN-PRINCIPLES.md); check what applies):

- [ ] New capabilities are exposed as file interfaces (9P), not libraries/RPC/bespoke protocols
- [ ] Data crossing 9P interfaces is plain text (no JSON inside the namespace)
- [ ] Access restriction is namespace shape (bind/mount), not policy checks on nameable paths
- [ ] New service/tool followed a namespace-sketch proposal issue (for non-trivial interfaces)
- [ ] Scripts that run inside Inferno are rc-style sh (no `&&`/`||`) and committed executable
- [ ] Irreversible/credentialed actions emit audit records; agent-facing effects have provenance emitters
- [ ] Anything this PR downloads or executes from outside the tree is pinned (commit SHA / revision URL) and checksum-verified
