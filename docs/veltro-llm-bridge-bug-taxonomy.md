# Veltro LLM-bridge bug taxonomy (Phase 0)

Status: living document. Phase 0 of the "systematically identify and fix"
program for the Anthropic↔OpenAI LLM bridge. This is the *characterization*
pass: catalogue the known and latent defect classes before any refactor, so
that the contained codec refactor (the recommended fix) can be done under a
safety net rather than blind.

## Scope

The bridge that lets the Veltro agent stack be driven by either the Anthropic
Messages API (`llmsrv -b api`, the default) or an OpenAI-compatible Chat
Completions backend (`llmsrv -b openai`, e.g. Ollama / gpt-oss / local
servers). Both providers are normalised by `appl/lib/llmclient.b` into a single
provider-agnostic wire format that the agent stack consumes:

```
STOP:<reason>
TOOL:<id>:<name>:<args-with-newlines-escaped>
[more TOOL: lines]
[optional trailing text]
```

The producer of this format lives in `appl/lib/llmclient.b`; the consumer lives
in `appl/veltro/agentlib.b`. **The two halves of the escaping contract are
defined in different files with no shared definition** — that split is the root
of defect class A below.

## Defect classes

### Class A — the escaping contract is asymmetric (data corruption)

The producer escapes args at three sites — `appl/lib/llmclient.b:283`,
`:431`, `:1067` — all identically:

```limbo
safeargs := replaceall(args, "\n", "\\n");   # newline -> backslash-n. Nothing else.
```

The consumer (`appl/veltro/agentlib.b:unescapenl`, lines 966–983) reverses
*two* escapes:

```limbo
'n'  => result += "\n";    # backslash-n -> newline
'\\' => result += "\\";    # backslash-backslash -> backslash
```

Because the producer never escapes a literal backslash but the consumer
*unescapes* one, `unescape(escape(x))` is **not** the identity whenever `x`
contains a backslash. Concrete, reproducible corruptions:

| ID  | Input args (literal bytes) | Round-trips to | Real-world trigger |
|-----|----------------------------|----------------|--------------------|
| A1  | `\n` (backslash, n)        | a real newline | a regex/grep pattern `\n`, a code snippet written via the `write`/`edit` tools, a JSON string value containing `\n` |
| A2  | `\\` (two backslashes)     | `\` (one)      | Windows UNC path `\\server\share`, escaped regex, LaTeX, JSON containing `\\` |
| A3  | real newline + literal `\n` mixed | ambiguous — the two cannot be distinguished after escaping | any tool arg mixing both |

**Root cause:** the producer must escape the escape character itself
(`\` → `\\`) *before* escaping the newline (`<NL>` → `\n`), so the inverse is
unambiguous. It currently does not. Any correct fix must make producer and
consumer exact inverses — ideally by defining both in **one** codec module so
they cannot drift again.

Severity: **high**. Silent data corruption of tool arguments. The
`grep`/`find`/`edit`/`write`/`git`/`json` tools routinely carry backslashes.

### Class B — unescaped field delimiters in `id` / `name`

The `TOOL:<id>:<name>:<args>` line is split on the first two colons
(`agentlib.b:parsetoolline`, lines 988–1009). `id` and `name` are interpolated
into the line **unescaped** (`llmclient.b:284`, `:432`, `:1067`). A colon in a
tool name or tool-use id mis-splits the line: the field boundary leaks into the
next field.

| ID  | Input | Parsed as |
|-----|-------|-----------|
| B1  | name = `foo:bar`, args = `X` → line `TOOL:tid:foo:bar:X` | name = `foo`, args = `bar:X` |

Severity: **low in practice** (Anthropic ids are `toolu_…`, OpenAI ids are
`call_…`, stock tool names have no colons) but **unguarded** — a future tool
name or a non-stock provider id could trip it with no defence. Args *after* the
second colon are safe (colons in args round-trip fine), because args is the
unparsed remainder; only `id`/`name` are vulnerable.

### Class C — duplicated hand-rolled JSON assembly across the two provider paths

`buildanthropicrequest` and `buildopenairequestjson` (plus their parse peers)
build/parse JSON by manual `jquote(...) + "..."` concatenation, with no shared
serializer. Notable trust seam: `llmclient.b:181` inserts the stored structured
content (`m.sc`) into the request **raw, unquoted** — a malformed `sc` value
corrupts the whole request body. The two paths are near-duplicates, so a fix in
one can silently miss the other. This is the maintainability tax that lets the
other classes recur.

Severity: **medium** (maintainability / latent). Not a single bug — a bug
*incubator*.

The one *correctness* defect within Class C (the raw `m.sc` splice) is fixed in
Phase 2 below; the duplication itself remains, now under a byte-exact net.

### Class D — already-fixed regressions in this subsystem (regression-guard targets)

Mined from history; listed so the characterization suite keeps them dead:

- **D1 — tool-arg ordering / verb stripping** (`9611a2d`,
  `llmclient.b:extracttoolargs`). The legacy "return `args` if present"
  shortcut dropped the `command` verb for `{command, args}`-shaped tools
  (`task`, `memory`), producing the "Tool X failed 3 consecutive times" loop;
  gpt-oss:20b's `{args, command}` ordering made a naive join emit
  `<args> <command>`. Fixed to canonical command-first ordering. Refs INFR-126.
- **D2 — identity leakage** (`9611a2d`, `lib/veltro/system.txt`, `meta.txt`).
  Model admitted its base ("I'm ChatGPT/GPT-4"). Prompt-level fix. INFR-130.
- **D3 — `reasoning_effort` / `think` gating by model** (`dea82eb`,
  `95b89b8`; `llmclient_think_gating_test.b`). gpt-oss requires `think:true`;
  mistral cannot have it. Model-name-sniffed in `buildopenairequestjson`.
- **D4 — SSE streaming fallbacks** (`llmclient_sse_fallback_test.b`).
  Buffered-vs-incremental and non-conforming OpenAI-shape backends.

## Phase-1 fix — landed

Classes A and B are fixed by a single shared codec, `module/wirefmt.m` +
`appl/lib/wirefmt.b`, loaded by **both** the producer (`appl/lib/llmclient.b`,
all four `encodetool` sites) and the consumer (`appl/veltro/agentlib.b`,
`parsellmresponse` → `wirefmt->parsetoolline`). The duplicate `unescapenl` /
`parsetoolline` were removed from `agentlib.b`, so there is now one definition
that cannot drift. `escapefield`/`unescapefield` are exact inverses and escape
`\` (`\\`), newline (`\n`) and `:` (`\:`) in every field, so `id`/`name`
delimiters and backslash-bearing args all round-trip verbatim. Verified live on
a Linux `emu`: `wireformat_test` 10/10, `agentlib_test` 27 passed / 8 skipped,
`llmsrv_test` 53 passed. The former A1/A2/B1 defect tests are now identity
regression guards. Class C (duplicated JSON assembly) is unaddressed — a
separate, larger refactor.

## Phase-2 fix — landed (Class C, partial)

The single *correctness* defect in Class C is fixed: `buildanthropicmessage`
(`appl/lib/llmclient.b`) no longer splices `m.sc` in raw. It now parses `m.sc`
via `readjsonstring` first (mirroring the guard the OpenAI path already had) and
falls back to the plain-text representation if the structured content is
malformed, so a bad `sc` can no longer corrupt the request body. The happy-path
bytes are unchanged.

To make any *future* de-duplication of the two builders safe, Phase 2 also adds
a byte-exact net: `buildanthropicrequest` is now exported, and
`tests/llmclient_reqshape_test.b` locks the byte-for-byte output of both
builders for a representative request — including the Anthropic
`cache_control` prompt-cache markers, whose exact bytes matter for cache prefix
matching — plus seam tests (valid `sc` splices and parses; malformed `sc` falls
back and the body still parses). Verified live: `llmclient_reqshape_test` 4/4,
`llmclient_think_gating_test` 5/5, `llmsrv_test` 53/53, with the Phase-1 suites
still green.

**Still open (Phase 3 candidate):** the actual duplication — the two
near-identical builders and the ~6 repeated `tool_use` structblock-reconstruction
sites — is unaddressed. The byte goldens here are the prerequisite net for that
refactor (whether a shared JSON-emit helper or a full `JValue`-tree migration).

## Phase-0 coverage delivered

`tests/wireformat_test.b` — round-trip characterization of the Class A and
Class B escaping/framing contract, driving the **real** consumer
(`agentlib->parsellmresponse` → `parsetoolline` → `unescapenl`) with the
producer's exact escaping recipe replicated as a test helper. Identity cases
are asserted as the spec (they pass today); the A1/A2/B1 defect cases are
pinned to their **current corrupted output** with `KNOWN DEFECT` annotations,
so the suite stays green and the corrupting fix later turns them red — forcing
a deliberate update to identity assertions when the codec is repaired.

## Recommended fix (for reference — not part of Phase 0)

Extract a single shared wire-format codec (build + parse + escape + unescape in
one module, used by both the `llmclient` producer and the `agentlib` consumer),
making escape/unescape exact inverses (escape `\` before `\n`) and encoding
`id`/`name` safely. This hardens the existing seam without moving it — a
refactor, not a re-architecture. The tests here are its safety net.
