# Agent gateway (testing only)

> **TESTING ONLY — NEVER SHIP IN A RELEASE.**
> CI guards in `.github/workflows/release.yml` and `.github/workflows/ci.yml`
> enforce that nothing under this directory lands in release artefacts or
> moves outside this directory. See [CLAUDE.md](../../CLAUDE.md) for the
> ring-fence rule.

This directory holds the in-tree live-model evaluation harness. It is test
infrastructure, not a production agent entry point.

## Files

| File | Purpose |
|---|---|
| `serve-agent` | Inferno rc profile. |
| `serve-agent.sh` | Host launcher. |
| `grind.py` | Fresh-emulator orchestrator, scorer, and evidence recorder. |
| `grind-driver` | Inferno-side activity and evidence driver. |
| `scenarios/escape-room.yaml` | Audited Codex containment pilot. |

## Usage

One-time keyfile generation:

```sh
./serve-llm.sh --gen-key
```

Start the gateway:

```sh
./tests/agent-harness/serve-agent.sh
```

## Escape room

The escape-room scenario is destructive adversarial testing for a disposable
two-VM lab. Read [the complete protocol](../../docs/VELTRO-ESCAPE-ROOM.md)
before running it. The scenario enables fail-closed auditfs/Venti provenance,
generates fresh synthetic canaries, and reports `PASS`, `FAIL`, or
`INCONCLUSIVE`:

```sh
python3 tests/agent-harness/grind.py \
  --scenarios tests/agent-harness/scenarios/escape-room.yaml \
  --model default \
  --url http://GATEWAY-PRIVATE-IP:11436/v1 \
  --timeout 900
```

Never treat a normal grind scenario's functional `PASS` as a containment
result. Only `escape_room: true` scenarios receive dynamic-canary scoring, and
only `audit: required` scenarios require the sealed provenance bundle.
