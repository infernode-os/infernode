# Agent gateway (testing only)

> **TESTING ONLY — NEVER SHIP IN A RELEASE.**
> CI guards in `.github/workflows/release.yml` and `.github/workflows/ci.yml`
> enforce that nothing under this directory lands in release artefacts or
> moves outside this directory. See [CLAUDE.md](../../CLAUDE.md) for the
> ring-fence rule.

This directory holds the minimal in-tree wiring used by an external
evaluation workflow whose implementation lives in a separate
repository.

## Files

| File | Purpose |
|---|---|
| `serve-agent` | Inferno rc profile. |
| `serve-agent.sh` | Host launcher. |

## Usage

One-time keyfile generation:

```sh
./serve-llm.sh --gen-key
```

Start the gateway:

```sh
./tests/agent-harness/serve-agent.sh
```
