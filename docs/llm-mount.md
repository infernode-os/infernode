# LLM Filesystem Mount for Inferno

This document describes how to use the LLM 9P filesystem with Inferno.

## Overview

The `llmsrv` service presents LLM providers (Anthropic API or Ollama/OpenAI-compatible)
as a 9P filesystem at `/mnt/llm`. Sessions are cloned from `/mnt/llm/new`, then prompts
are written to `/mnt/llm/{id}/ask` and responses read back from the same file.

## Local Service

llmsrv runs inside the Inferno emulator and self-mounts at `/mnt/llm`. The shell
profile (`lib/sh/profile`) starts it automatically:

```sh
llmsrv >[2] /dev/null &
```

Backend and model can be configured via flags:

```sh
# Anthropic API (default)
llmsrv &

# Ollama / OpenAI-compatible
llmsrv -b openai -u http://localhost:11434/v1 -M qwen3-coder:30b &
```

The Settings app (`LLM Service` category) provides a GUI for this configuration.

## Remote Service

Mount a remote llmsrv (or any compatible 9P LLM server) via dial+mount:

```sh
mount -A 'tcp!hephaestus!5640' /mnt/llm >[2] /dev/null
```

With `mode=remote` in `/lib/ndb/llm`, the profile (and `lib/lucifer/llmsrv.sh` at GUI
boot) mounts the `dial=` address. With `auth=keyring` it authenticates with a keyfile
(`keyfile=`, default `/lib/keyring/serve-llm`) instead of `-A`:

```sh
mount -k /lib/keyring/serve-llm 'tcp!llmhost!5640' /mnt/llm
```

The Settings app can configure this as well — select "Remote (9P)" and enter
the dial address. Apply does the mount immediately; "Save to Profile" persists
it for next startup.

## Filesystem Structure

```
/mnt/llm/
├── new          # Read to clone a new session (returns its id, an unguessable token)
├── models       # Read the backend's available models
└── {id}/
    ├── ask          # Write prompt, read response
    ├── stream       # Read streaming response chunks
    ├── model        # Read/write model name
    ├── temperature  # Read/write, 0.0-2.0
    ├── system       # Read/write system prompt
    ├── thinking     # Read/write: "disabled", "max" or a token budget
    ├── prefill      # Read/write assistant response prefill
    ├── tools        # Write tool definitions (JSON)
    ├── context      # Read conversation history (JSON); write one back, between turns
    ├── compact      # Write to trigger compaction
    ├── ctl          # Write "reset" or "close"
    ├── usage        # Read "estimated_tokens/window"
    ├── window       # Read/write: the context window, in tokens (see below)
    ├── maxtokens    # Read/write: the output cap; 0 (the default) is the backend's
    └── reasoning    # Read/write
```

Session directories are not listed in `/mnt/llm`; a session is reachable only by the
id its creator read from `new`.

## The context window

A session's history is compacted before it outgrows the window its model
runs in.  The window is the backend's word, learned per model the first time
a session asks: `max_model_len` from an OpenAI-shape server's `/v1/models`
(vLLM, SGLang), the window Ollama runs the model with (`/api/ps`, or its
`num_ctx`; Ollama cuts a longer prompt from the front, silently), the
Anthropic models endpoint's `max_input_tokens`.  Where the backend does not
say, `window=<tokens>` in `/lib/ndb/llm` says (`llmsrv -C`); a session's own
is written to its `window` file.  A backend that refuses a prompt as too long
is the last word: llmsrv learns the window from the refusal, compacts, and
asks again.

The mark is the window less room for the reply: a quarter of it, at least
16K tokens.  `autocompact=<tokens>` (`llmsrv -c`) or `ctl autocompact <n>`
sets one instead; `ctl autocompact auto` returns to the window's.  In a long
agent turn the history is compacted between the turn's steps, the step under
way kept, so a turn of many tool calls does not outgrow the window before it
ends.

## Usage from Inferno Shell

### Simple Query
```sh
id=`{cat /mnt/llm/new}
echo 'What is the capital of France' > /mnt/llm/$id/ask
cat /mnt/llm/$id/ask
```

## Troubleshooting

### /mnt/llm doesn't exist

1. Ensure you started emu through the shell: `sh -l -c 'xenith'`
2. Check `/lib/ndb/llm`: the profile starts `llmsrv` (local mode) or runs `mount -A` / `mount -k` (`mode=remote`)
3. For remote: verify the remote host is reachable

### Connection refused (remote)

The remote LLM service is not running or not listening on the expected port.

## Architecture Notes

Xenith forks its namespace at startup (`sys->pctl(Sys->FORKNS, ...)`), which
means mounts done from within Xenith are isolated. The profile mount happens
before Xenith starts, ensuring the LLM mount is inherited by Xenith's namespace.
