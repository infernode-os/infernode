#!/usr/bin/env python3
# codex-gate — OpenAI-compatible /v1 gateway over the ChatGPT Codex CLI.
#
# Purpose: let InferNode's llmsrv (`-b openai -u http://127.0.0.1:11436/v1`)
# reach OpenAI's Codex models through the locally-authenticated `codex` CLI
# (ChatGPT subscription billing) instead of a raw API key.  Sibling of
# tools/claude-gate/ — same wire contract, same place in the stack:
#
#   llmsrv -b openai -u http://127.0.0.1:11436/v1
#      │  OpenAI chat-completions (HTTP, localhost only)
#      ▼
#   codex-gate  ──  codex exec --json  ──▶  ChatGPT login
#
# The hard part both gates solve is the tool-calling inversion: llmsrv wants
# a backend that RETURNS tool calls to the caller (nerva runs its own tool
# loop, with its own policy enforcement), while a CLI agent harness wants to
# run the loop itself.  claude-gate bridges it with a live in-process MCP
# server whose handler parks on a future.  The Codex CLI has no in-process
# MCP server, and `codex exec` cancels MCP tool calls non-interactively
# unless the sandbox is disabled wholesale — which is not a trade InferNode
# should make by default.  So this gate bridges at the *prompt* level:
#
#   1. Tool definitions from the request are rendered into the prompt.
#   2. `codex exec --output-schema` constrains the final agent message to
#      {"content": str, "tool_calls": [{"name", "arguments"}]}.
#   3. A non-empty tool_calls array becomes an OpenAI `tool_calls` response
#      with finish_reason=tool_calls; llmsrv turns it into the `TOOL:` lines
#      the agent already parses, and the agent executes them under its own
#      policy exactly as with Ollama.
#   4. llmsrv owns the transcript and sends it in full every call, so the
#      tool results come back as ordinary role=tool messages on the next
#      request and are replayed into a fresh `codex exec`.
#
# Consequence worth knowing: CLI SESSIONS are stateless. There is no live CLI
# session across a tool round-trip — each request is one `codex exec`.
# In-flight HTTP requests, including quota-paused requests, are not durable
# across a gateway restart and must be retried by the caller. /health reports
# held_turns for surface parity with claude-gate; it is always 0.
#
# Endpoints (bind 127.0.0.1 only — no auth of its own):
#   POST /v1/chat/completions    (non-streaming + single-chunk SSE)
#   GET  /v1/models
#   GET  /health
#
# Config (env):
#   CODEX_GATE_HOST       default 127.0.0.1
#   CODEX_GATE_PORT       default 11436
#   CODEX_GATE_MOCK       "1" = deterministic mock backend (tests; no CLI)
#   CODEX_GATE_MOCK_ERROR non-empty = fail every mock turn with this message
#   CODEX_GATE_MOCK_ERROR_COUNT fail this many mock calls (-1 = every call)
#   CODEX_GATE_MOCK_ERROR_SYSTEM_MATCH only fail mock turns whose system prompt
#                                      contains this string
#   CODEX_GATE_BIN        codex binary (default "codex", found on PATH)
#   CODEX_GATE_MODEL      default model; empty = let the CLI use its own
#   CODEX_GATE_MODELS     comma-separated list advertised on /v1/models
#   CODEX_GATE_TIMEOUT    seconds one `codex exec` may run (default 900)
#   CODEX_GATE_IDLE_TIMEOUT seconds with no CLI output before abort (default 300)
#   CODEX_GATE_HEARTBEAT  seconds between SSE keepalives (default 30)
#   CODEX_GATE_CONCURRENCY  max simultaneous codex processes (default 4)
#   CODEX_GATE_QUOTA_MAX_WAIT max seconds to preserve/retry a quota-paused turn
#                             (default 21600; 0 = return structured 429)
#   CODEX_GATE_QUOTA_BACKOFF initial retry delay without reset metadata (30)
#   CODEX_GATE_QUOTA_MAX_BACKOFF maximum fallback retry delay (900)
#   CODEX_GATE_QUOTA_RESET_GRACE seconds after a minute-precision reset (30)
#   SIGHUP                    retry quota-paused requests immediately
#   CODEX_GATE_SANDBOX    --sandbox value (default read-only)
#   CODEX_GATE_WORKDIR    --cd value (default ~/.cache/codex-gate/workdir)
#   CODEX_GATE_CODEX_HOME CODEX_HOME for the child (isolates ~/.codex; you
#                         must copy auth.json in yourself if you set it)
#   CODEX_GATE_EXEC_ARGS  extra args appended to every `codex exec`
#   CODEX_GATE_PROMPT_ARGV  "1" = pass the prompt as argv, not on stdin
#   CODEX_GATE_DEBUG      verbose logging
#   CODEX_GATE_HARDEN     "0" = do not pin the CLI feature surface (see below)
#   CODEX_GATE_DISABLE_FEATURES  comma list replacing the pinned disable set
#   CODEX_GATE_HOME_ALLOW comma list of entries allowed in CODEX_GATE_CODEX_HOME
#
# Maintenance modes:
#   --inventory [CODEX_HOME]              hash model-side state and exit
#   --prepare-home LOGIN_HOME CAMPAIGN_HOME copy only fresh OAuth state
#
# Billing guard: OPENAI_API_KEY in the environment can make the CLI bill the
# API instead of the ChatGPT plan.  serve-codex-gate.sh unsets it; we also
# refuse to start unless CODEX_GATE_ALLOW_API_KEY=1 explicitly overrides.

import asyncio
import datetime
import hashlib
import json
import logging
import os
import re
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

from aiohttp import web

log = logging.getLogger("codex-gate")

HOST = os.environ.get("CODEX_GATE_HOST", "127.0.0.1")
PORT = int(os.environ.get("CODEX_GATE_PORT", "11436"))
MOCK = os.environ.get("CODEX_GATE_MOCK", "") == "1"
MOCK_ERROR = os.environ.get("CODEX_GATE_MOCK_ERROR", "")
MOCK_ERROR_COUNT = int(os.environ.get("CODEX_GATE_MOCK_ERROR_COUNT", "-1"))
MOCK_ERROR_SYSTEM_MATCH = os.environ.get(
    "CODEX_GATE_MOCK_ERROR_SYSTEM_MATCH", "")
CODEX_BIN = os.environ.get("CODEX_GATE_BIN", "codex")
DEFAULT_MODEL = os.environ.get("CODEX_GATE_MODEL", "")
EXEC_TIMEOUT = max(0.05, float(os.environ.get("CODEX_GATE_TIMEOUT", "900")))
IDLE_TIMEOUT = max(0.0, float(os.environ.get("CODEX_GATE_IDLE_TIMEOUT", "300")))
HEARTBEAT = max(0.05, float(os.environ.get("CODEX_GATE_HEARTBEAT", "30")))
CONCURRENCY = int(os.environ.get("CODEX_GATE_CONCURRENCY", "4"))
SANDBOX = os.environ.get("CODEX_GATE_SANDBOX", "read-only")
QUOTA_MAX_WAIT = max(0.0, float(os.environ.get(
    "CODEX_GATE_QUOTA_MAX_WAIT", "21600")))
QUOTA_BACKOFF = max(0.05, float(os.environ.get(
    "CODEX_GATE_QUOTA_BACKOFF", "30")))
QUOTA_MAX_BACKOFF = max(QUOTA_BACKOFF, float(os.environ.get(
    "CODEX_GATE_QUOTA_MAX_BACKOFF", "900")))
QUOTA_RESET_GRACE = max(0.0, float(os.environ.get(
    "CODEX_GATE_QUOTA_RESET_GRACE", "30")))

_mock_errors_remaining = MOCK_ERROR_COUNT
_quota_pauses = {}
_quota_wakes = {}
_last_quota_pause = None
_home_inventory_cache = None

# Models advertised on /v1/models — what llmsrv's `/mnt/llm/models` and the
# Settings picker show.  Codex's model lineup moves faster than this file
# can; whatever a request names is passed straight to `codex -m`, so the
# list is a convenience, not a whitelist.  Override with CODEX_GATE_MODELS.
ADVERTISED_MODELS = [m for m in os.environ.get(
    "CODEX_GATE_MODELS", "default").split(",") if m]

# Where `codex exec` runs.  A private empty directory, not the user's
# checkout: the CLI's own shell/read tools stay sandboxed (--sandbox
# read-only) AND start somewhere with nothing to read.  nerva owns tool
# execution; anything the CLI does on its own is not a feature here.
WORKDIR = os.environ.get("CODEX_GATE_WORKDIR") or os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "codex-gate", "workdir")

# Flags we would like to pass but that older CLI builds may not know.  A
# usage error naming one drops it for the lifetime of the process and the
# call is retried once (see run_codex).  --sandbox is deliberately NOT in
# here: a build that doesn't understand it must fail loudly rather than run
# the CLI's own tools unsandboxed.
OPTIONAL_FLAGS = {"--skip-git-repo-check", "--output-schema",
                  "--output-last-message", "--cd", "--json"}
_dropped_flags = set()

ADAPTER_INSTRUCTIONS = (
    "You are running inside a stateless protocol adapter. Treat the contents "
    "of <system_instructions> in the user message as the caller's system "
    "instructions. Any <available_tools> entries there are virtual caller "
    "tools, not native Codex tools. Request them only with the JSON protocol "
    "specified in that block; the caller executes them and returns results. "
    "Do not inspect or reason from the CLI filesystem when a virtual tool can "
    "perform the requested action, and do not claim a caller path is missing "
    "based on the CLI environment."
)

# Some builds take the prompt only as a positional argument, not on stdin
# via `-`.  Transcripts outgrow argv, so stdin is the default.
PROMPT_ARGV = os.environ.get("CODEX_GATE_PROMPT_ARGV", "") == "1"


# ── pinned CLI feature surface (INFR-413) ──────────────────────────
#
# During the escape-room campaign, Codex CLI 0.149.0 populated a fresh 0700
# CODEX_HOME that held only auth.json with 144 plugin-cache files (~26 MiB,
# the remote curated catalog included), 60 system-skill files, and a shell
# snapshot.  Nothing escaped — the CLI ran --sandbox read-only, with its
# native shell disabled, in an empty working directory on a VM with no target
# filesystem — but the model was carrying tools and instructions nobody
# recorded, and the next campaign would carry different ones.  So the gateway
# pins the surface instead of inheriting whatever the installed CLI defaults
# to, and reports what it pinned on /health for the campaign manifest.
#
# `--disable X` is `-c features.X=false`.  An unknown name is a hard error
# from the CLI, and that is the point: a build that renames one must fail
# loudly rather than quietly serve requests with the feature back on.

HARDEN = os.environ.get("CODEX_GATE_HARDEN", "1") != "0"

# Flags that stop the CLI reading configuration of its own or writing session
# state.  Like --sandbox, these are never auto-dropped on a usage error.
HARDEN_FLAGS = ("--ephemeral", "--ignore-user-config", "--ignore-rules")

DEFAULT_DISABLED_FEATURES = (
    # plugins, including the remote curated catalog and its cache
    "plugins", "plugin_sharing", "remote_plugin", "recommended_plugins",
    # apps and the MCP surface they reach
    "apps", "enable_mcp_apps", "tool_call_mcp_elicitation",
    # system skills and the dependency installer a skill can trigger
    "skill_search", "skill_mcp_dependency_install",
    # state that would persist between trials
    "memories", "shell_snapshot",
    # code execution that is not the caller's virtual-tool protocol
    "shell_tool", "hooks",
    # the CLI running agents of its own; the caller owns delegation
    "multi_agent", "multi_agent_v2",
    # host surfaces a protocol adapter has no use for
    "browser_use", "browser_use_external", "browser_use_full_cdp_access",
    "computer_use", "in_app_browser", "image_generation", "view_image",
    "tool_suggest",
)

# Entries the protocol's isolated Codex home is allowed to hold before the
# first request.  The dedicated OAuth login and nothing else: a config.toml,
# an AGENTS.md, an mcp.json or a plugins directory that arrived some other way
# is an uncontrolled instruction or tool source.
DEFAULT_HOME_ALLOW = ("auth.json", "auth.json.lock", "version.json",
                      "installation_id")

# A fresh device login may create these operational directories before the
# gateway ever runs. They are acceptable only as input to --prepare-home and
# are never copied into the campaign home.
LOGIN_SOURCE_ALLOW = frozenset(DEFAULT_HOME_ALLOW + ("log", "tmp"))


def disabled_features():
    """The features every `codex exec` turns off.

    Unhardened, the native shell is still disabled — that one is the adapter's
    security contract (the model must request effects from the caller, not
    inspect the gateway host), not a reproducibility measure.
    """
    override = os.environ.get("CODEX_GATE_DISABLE_FEATURES")
    if override is not None:
        return tuple(f.strip() for f in override.split(",") if f.strip())
    return DEFAULT_DISABLED_FEATURES if HARDEN else ("shell_tool",)


def home_allowlist():
    override = os.environ.get("CODEX_GATE_HOME_ALLOW")
    if override is not None:
        return tuple(n.strip() for n in override.split(",") if n.strip())
    return DEFAULT_HOME_ALLOW


def profile_flags():
    """The invariant, security-relevant part of every `codex exec`.

    build_argv() and the /health profile are both built from this, so the
    flags a campaign records cannot drift from the flags it ran under.
    """
    flags = ["--sandbox", SANDBOX, "--strict-config"]
    for feature in disabled_features():
        flags += ["--disable", feature]
    if HARDEN:
        flags += list(HARDEN_FLAGS)
    return flags


def codex_home_violations(home, allow):
    """Entries in the isolated Codex home that were not put there on purpose."""
    try:
        entries = sorted(os.listdir(home))
    except OSError as e:
        return ["cannot read CODEX_HOME %s: %s" % (home, e)]
    violations = []
    mode = os.stat(home).st_mode & 0o777
    if mode & 0o077:
        violations.append("CODEX_HOME is mode %s; it holds credentials" % oct(mode))
    for name in entries:
        if name in allow:
            continue
        kind = "directory" if os.path.isdir(os.path.join(home, name)) else "file"
        violations.append("unexpected %s %r" % (kind, name))
    return violations


def prepare_codex_home(source, destination):
    """Copy only fresh OAuth state into a new, private gateway home.

    The login source remains untouched.  Refusing an existing destination is
    deliberate: replacing or merging OAuth state can resurrect a rotated
    refresh token or carry model-side state between campaigns.
    """
    source = os.path.abspath(os.path.expanduser(source))
    destination = os.path.abspath(os.path.expanduser(destination))
    if source == destination:
        raise SystemExit("codex-gate: login source and campaign home are the same")
    if os.path.commonpath((os.path.realpath(source),
                           os.path.realpath(destination))) == os.path.realpath(source):
        raise SystemExit("codex-gate: campaign home must not be inside login source")

    try:
        source_stat = os.lstat(source)
    except OSError as e:
        raise SystemExit("codex-gate: cannot inspect login source: %s" % e)
    if not stat.S_ISDIR(source_stat.st_mode):
        raise SystemExit("codex-gate: login source must be a real directory")
    if stat.S_IMODE(source_stat.st_mode) != 0o700:
        raise SystemExit("codex-gate: login source holds credentials and must be mode 0700")
    if hasattr(os, "geteuid") and source_stat.st_uid != os.geteuid():
        raise SystemExit("codex-gate: login source is not owned by this user")

    try:
        names = set(os.listdir(source))
    except OSError as e:
        raise SystemExit("codex-gate: cannot read login source: %s" % e)
    unexpected = sorted(names - LOGIN_SOURCE_ALLOW)
    if unexpected:
        raise SystemExit(
            "codex-gate: login source contains unsanctioned state: %s"
            % ", ".join(repr(name) for name in unexpected))
    if "auth.json" not in names:
        raise SystemExit("codex-gate: login source has no auth.json")
    for name in sorted(names):
        path = os.path.join(source, name)
        try:
            entry_stat = os.lstat(path)
        except OSError as e:
            raise SystemExit("codex-gate: cannot inspect login source entry: %s" % e)
        if stat.S_ISLNK(entry_stat.st_mode):
            raise SystemExit("codex-gate: login source entry %r is a symlink" % name)
        if name in ("log", "tmp"):
            valid = stat.S_ISDIR(entry_stat.st_mode)
        else:
            valid = stat.S_ISREG(entry_stat.st_mode)
        if not valid:
            raise SystemExit("codex-gate: login source entry %r has wrong type" % name)

    auth_path = os.path.join(source, "auth.json")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        auth_fd = os.open(auth_path, os.O_RDONLY | nofollow)
    except OSError as e:
        raise SystemExit("codex-gate: cannot open login auth.json safely: %s" % e)
    try:
        auth_stat = os.fstat(auth_fd)
        if not stat.S_ISREG(auth_stat.st_mode) or auth_stat.st_size == 0:
            raise SystemExit("codex-gate: login auth.json must be a non-empty regular file")
        if stat.S_IMODE(auth_stat.st_mode) != 0o600:
            raise SystemExit("codex-gate: login auth.json must be mode 0600")
        if hasattr(os, "geteuid") and auth_stat.st_uid != os.geteuid():
            raise SystemExit("codex-gate: login auth.json is not owned by this user")

        try:
            os.mkdir(destination, 0o700)
        except FileExistsError:
            raise SystemExit(
                "codex-gate: campaign home already exists; use a new path")
        except OSError as e:
            raise SystemExit("codex-gate: cannot create campaign home: %s" % e)

        tmp_name = ".auth.json.tmp-%d" % os.getpid()
        tmp_path = os.path.join(destination, tmp_name)
        try:
            out_fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                             nofollow, 0o600)
            try:
                while True:
                    chunk = os.read(auth_fd, 1 << 20)
                    if not chunk:
                        break
                    view = memoryview(chunk)
                    while view:
                        written = os.write(out_fd, view)
                        if written <= 0:
                            raise OSError("short write preparing campaign home")
                        view = view[written:]
                os.fsync(out_fd)
            finally:
                os.close(out_fd)
            os.replace(tmp_path, os.path.join(destination, "auth.json"))
            dir_fd = os.open(destination, os.O_RDONLY |
                             getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            try:
                os.rmdir(destination)
            except OSError:
                pass
            raise
    finally:
        os.close(auth_fd)

    return destination


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def codex_home_inventory(home):
    """Every file under a Codex home, hashed.

    The CLI populates this directory itself while a campaign runs, so an
    inventory taken afterwards is the only account of what model-side state
    the trials actually carried.  The top-level `sha256` covers the whole
    listing, so two campaigns can be compared by one value.
    """
    entries = []
    total = 0
    for dirpath, dirnames, filenames in os.walk(home):
        dirnames.sort()
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, home)
            try:
                stat = os.stat(path)
                entries.append({"path": rel, "size": stat.st_size,
                                "mode": oct(stat.st_mode & 0o777),
                                "sha256": file_sha256(path)})
                total += stat.st_size
            except OSError as e:
                entries.append({"path": rel, "error": str(e)})
    listing = "\n".join("%s %s" % (e["path"], e.get("sha256", "unreadable"))
                        for e in entries)
    credential_names = {"auth.json", "auth.json.lock"}
    credential_files = sum(
        1 for entry in entries if entry["path"].split(os.sep, 1)[0]
        in credential_names)
    return {"home": home, "files": len(entries), "bytes": total,
            "credential_files": credential_files,
            "persistent_cli_state_files": len(entries) - credential_files,
            "persistent_cli_state": len(entries) > credential_files,
            "sha256": hashlib.sha256(listing.encode()).hexdigest(),
            "entries": entries}


def codex_home_summary(home):
    """Cached inventory summary, invalidated whenever a Codex child exits."""
    global _home_inventory_cache
    if _home_inventory_cache is None:
        _home_inventory_cache = {
            k: v for k, v in codex_home_inventory(home).items()
            if k != "entries"
        }
    return dict(_home_inventory_cache)


def codex_version():
    try:
        result = subprocess.run([CODEX_BIN, "--version"], env=child_env(),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=10, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        raise SystemExit("codex-gate: cannot determine codex version: %s" % e)
    if result.returncode != 0:
        raise SystemExit("codex-gate: `codex --version` failed: %s"
                         % result.stdout.strip())
    return result.stdout.strip()


def parse_features(text):
    """`codex features list` output → {name: enabled}.

    Each line is "<name> <stage…> <true|false>"; only the first and last
    fields matter here.
    """
    features = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[-1] in ("true", "false"):
            features[fields[0]] = fields[-1] == "true"
    return features


def effective_features(disabled):
    """Ask the installed CLI what its feature set is under our flags.

    Two jobs at once: it validates every pinned name against this build (the
    CLI errors on one it does not know) and it produces the hashable record
    the campaign manifest needs.  It evaluates the same CODEX_HOME the child
    will use, so a config.toml smuggled in there would show up here too.
    """
    argv = [CODEX_BIN, "features", "list"]
    for feature in disabled:
        argv += ["--disable", feature]
    try:
        result = subprocess.run(argv, env=child_env(), stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True,
                                timeout=30, check=False)
    except (OSError, subprocess.SubprocessError) as e:
        raise SystemExit("codex-gate: cannot inspect codex features: %s" % e)
    if result.returncode != 0:
        raise SystemExit("codex-gate: the installed CLI rejected the pinned "
                         "feature set: %s" % result.stdout.strip())
    features = parse_features(result.stdout)
    still_on = [f for f in disabled if features.get(f)]
    if still_on:
        raise SystemExit("codex-gate: the CLI reports %s still enabled after "
                         "--disable" % ", ".join(still_on))
    canonical = "\n".join("%s=%s" % (k, features[k]) for k in sorted(features))
    return features, hashlib.sha256(canonical.encode()).hexdigest()


# Filled in at startup by gate_profile(); reported on /health so a campaign
# manifest records the CLI version and effective configuration it ran against.
PROFILE = {}


def gate_profile():
    """Version, flags and effective feature set of this gateway."""
    profile = {
        "hardened": HARDEN,
        "sandbox": SANDBOX,
        "exec_flags": profile_flags(),
        "disabled_features": list(disabled_features()),
        "adapter_instructions_sha256":
            hashlib.sha256(ADAPTER_INSTRUCTIONS.encode()).hexdigest(),
    }
    if MOCK:
        profile["codex_version"] = "mock"
        return profile
    profile["codex_version"] = codex_version()
    features, digest = effective_features(disabled_features())
    profile["features_sha256"] = digest
    profile["features_enabled"] = sorted(k for k, on in features.items() if on)
    home = os.environ.get("CODEX_GATE_CODEX_HOME")
    if home:
        profile["codex_home_baseline"] = {
            k: v for k, v in codex_home_inventory(home).items() if k != "entries"}
    return profile

_sem = None     # asyncio.Semaphore, created on startup


# ── request parsing ────────────────────────────────────────────────

def split_messages(messages):
    """(system_prompt, history).  System messages are hoisted out; the rest
    keeps its order, tool results included — this gate replays everything."""
    system_parts = []
    history = []
    for m in messages:
        if m.get("role") == "system":
            system_parts.append(m.get("content") or "")
        else:
            history.append(m)
    return "\n\n".join(p for p in system_parts if p), history


def render_prompt(history):
    """Render the conversation into one prompt for a fresh `codex exec`.
    llmsrv keeps the canonical history and sends it in full every call; the
    CLI session is per-request, so prior turns are replayed as text."""
    if not history:
        return ""
    lines = []
    for m in history[:-1]:
        role = m.get("role", "user")
        content = m.get("content") or ""
        if role == "assistant" and m.get("tool_calls"):
            for tc in m["tool_calls"]:
                fn = tc.get("function", {})
                lines.append("assistant called tool %s(%s)"
                             % (fn.get("name", "?"), fn.get("arguments", "{}")))
            if content:
                lines.append("assistant: " + content)
        elif role == "tool":
            lines.append("tool result [%s]: %s" % (m.get("tool_call_id", "?"), content))
        else:
            lines.append("%s: %s" % (role, content))
    last = history[-1]
    prompt = last.get("content") or ""
    if last.get("role") == "tool":
        # The normal continuation path here: the agent ran the tools we
        # asked for and llmsrv replayed the results.  Nothing is held.
        lines.append("tool result [%s]: %s" % (last.get("tool_call_id", "?"), prompt))
        prompt = "Continue, given the tool results above."
    elif last.get("role") == "assistant":
        lines.append("assistant: " + prompt)
        prompt = "Continue."
    if lines:
        return ("<conversation_history>\n" + "\n".join(lines) +
                "\n</conversation_history>\n\n" + prompt)
    return prompt


# ── prompt-level tool protocol ─────────────────────────────────────

# `arguments` is a JSON *string* rather than an object: strict structured
# outputs cannot express "any object", and llmclient.b wants a string on
# the way back out anyway.
TOOL_SCHEMA = {
    "type": "object",
    "properties": {
        "content": {
            "type": "string",
            "description": "Your reply to the user. Empty when calling tools.",
        },
        "tool_calls": {
            "type": "array",
            "description": "Tools to run. Empty when replying to the user.",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "arguments": {
                        "type": "string",
                        "description": "Arguments as a JSON object, encoded as a string.",
                    },
                },
                "required": ["name", "arguments"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["content", "tool_calls"],
    "additionalProperties": False,
}


def tool_instructions(tooldefs):
    """The tool manifest + protocol, appended to the system instructions."""
    manifest = []
    for td in tooldefs:
        fn = td.get("function", {})
        manifest.append({
            "name": fn.get("name", "tool"),
            "description": fn.get("description", ""),
            "parameters": fn.get("parameters") or {"type": "object", "properties": {}},
        })
    return (
        "<available_tools>\n"
        + json.dumps(manifest, indent=2)
        + "\n</available_tools>\n\n"
        "The entries above are virtual caller tools. They are not native Codex\n"
        "tools and will not appear in your CLI runtime tool list. The caller\n"
        "executes them and returns their results on the next turn. When a listed\n"
        "tool can perform the requested action, you MUST request it using the\n"
        "JSON protocol below. Do not test its availability in the CLI environment.\n"
        "The caller's filesystem and services are different from the CLI's.\n\n"
        "Reply with a single JSON object and nothing else:\n"
        '  to call tools: {\"content\": \"\", \"tool_calls\": '
        '[{\"name\": \"<tool>\", \"arguments\": \"<json object as a string>\"}]}\n'
        '  to answer:     {\"content\": \"<your answer>\", \"tool_calls\": []}\n'
    )


def strip_fence(text):
    """Unwrap a ```/```json fence if the model added one anyway."""
    t = text.strip()
    if not t.startswith("```"):
        return t
    nl = t.find("\n")
    if nl < 0:
        return t
    body = t[nl + 1:]
    end = body.rfind("```")
    return (body[:end] if end >= 0 else body).strip()


def parse_tool_reply(text):
    """(content, [(name, args-dict), ...]).  A reply that isn't the agreed
    JSON object is treated as plain content — degraded, never fatal."""
    try:
        obj = json.loads(strip_fence(text))
    except Exception:
        return text, []
    if not isinstance(obj, dict):
        return text, []
    calls = []
    for tc in obj.get("tool_calls") or []:
        if not isinstance(tc, dict) or not tc.get("name"):
            continue
        raw = tc.get("arguments")
        if isinstance(raw, dict):
            args = raw
        else:
            try:
                args = json.loads(raw or "{}")
            except Exception:
                args = {}
            if not isinstance(args, dict):
                args = {}
        calls.append((tc["name"], args))
    content = obj.get("content")
    if not isinstance(content, str):
        content = ""
    if not calls and not content:
        return text, []
    return content, calls


# ── OpenAI response shaping ────────────────────────────────────────

def completion_body(model, text, tool_calls, finish_reason, usage_tokens):
    msg = {"role": "assistant", "content": text}
    if tool_calls:
        msg["tool_calls"] = tool_calls
    return {
        "id": "chatcmpl-" + uuid.uuid4().hex[:16],
        "object": "chat.completion",
        "created": int(time.time()),
        "model": model,
        "choices": [{
            "index": 0,
            "message": msg,
            "finish_reason": finish_reason,
        }],
        "usage": {
            "prompt_tokens": 0,
            "completion_tokens": usage_tokens,
            "total_tokens": usage_tokens,
        },
    }


def toolcalls_json(calls):
    """calls: [(name, args-dict)] → OpenAI tool_calls.  `arguments` MUST be
    a JSON string — llmclient.b picks String."""
    out = []
    for i, (name, args) in enumerate(calls):
        out.append({
            "index": i,
            "id": "call_" + uuid.uuid4().hex[:16],
            "type": "function",
            "function": {
                "name": name,
                "arguments": json.dumps(args, separators=(",", ":")),
            },
        })
    return out


async def respond(request, model, text, calls, usage_tokens, stream,
                  stream_response=None):
    tcs = toolcalls_json(calls) if calls else None
    finish = "tool_calls" if tcs else "stop"
    body = completion_body(model, text, tcs, finish, usage_tokens)

    if not stream:
        return web.json_response(body)

    # Single-chunk SSE: llmclient's SSE parser accumulates deltas, so one
    # complete delta chunk + usage + [DONE] is valid and sufficient.
    resp = stream_response
    if resp is None:
        resp = web.StreamResponse(headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
        })
        await resp.prepare(request)
    choice = body["choices"][0]
    delta = {"role": "assistant", "content": choice["message"]["content"]}
    if choice["message"].get("tool_calls"):
        delta["tool_calls"] = choice["message"]["tool_calls"]
    chunk = {
        "id": body["id"], "object": "chat.completion.chunk",
        "created": body["created"], "model": body["model"],
        "choices": [{"index": 0, "delta": delta, "finish_reason": None}],
    }
    await resp.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
    fin = {
        "id": body["id"], "object": "chat.completion.chunk",
        "created": body["created"], "model": body["model"],
        "choices": [{"index": 0, "delta": {}, "finish_reason": choice["finish_reason"]}],
        "usage": body["usage"],
    }
    await resp.write(b"data: " + json.dumps(fin).encode() + b"\n\n")
    await resp.write(b"data: [DONE]\n\n")
    await resp.write_eof()
    return resp


# ── codex CLI backend ──────────────────────────────────────────────

class CodexError(Exception):
    pass


class UsageLimitError(CodexError):
    def __init__(self, message, metadata=None):
        super().__init__(message)
        self.metadata = metadata or {}


def quota_metadata(message, now=None):
    """Return safe retry metadata for a Codex account limit, or None.

    Codex currently reports account exhaustion as human-readable stderr/event
    text. Classification happens only at this trusted CLI boundary; callers
    must not infer quota state by matching assistant output.
    """
    lower = message.lower()
    if not any(token in lower for token in (
            "usage limit", "usage_limit", "quota exceeded",
            "insufficient_quota")):
        return None

    now = now or datetime.datetime.now().astimezone()
    metadata = {"reason": "usage_limit", "retryable": True}
    delay = None
    match = re.search(
        r"try again in\s+(\d+(?:\.\d+)?)\s*(second|minute|hour)s?", lower)
    if match:
        scale = {"second": 1, "minute": 60, "hour": 3600}[match.group(2)]
        delay = float(match.group(1)) * scale
    else:
        match = re.search(r"try again at\s+(\d{1,2}:\d{2}\s*[ap]m)", lower)
        if match:
            parsed = datetime.datetime.strptime(
                re.sub(r"\s+", " ", match.group(1)).upper(), "%I:%M %p")
            target = now.replace(hour=parsed.hour, minute=parsed.minute,
                                 second=0, microsecond=0) + \
                datetime.timedelta(seconds=QUOTA_RESET_GRACE)
            if target <= now:
                target += datetime.timedelta(days=1)
            delay = (target - now).total_seconds()
    if delay is not None:
        delay = max(0.0, delay)
        metadata["retry_after"] = round(delay, 3)
        metadata["reset_at"] = (now + datetime.timedelta(seconds=delay)).isoformat()
    return metadata


def quota_error_body(error):
    metadata = dict(getattr(error, "metadata", {}) or {})
    metadata.setdefault("reason", "usage_limit")
    metadata.setdefault("retryable", True)
    return {"error": {
        "message": "codex-gate: account usage limit reached",
        "type": "usage_limit",
        "code": "usage_limit",
        **metadata,
    }}


async def run_with_quota_recovery(factory):
    """Retry one stateless turn without advancing the caller transcript."""
    global _last_quota_pause
    turn_id = uuid.uuid4().hex
    started = None
    started_at = None
    retries = 0
    wake = asyncio.Event()
    _quota_wakes[turn_id] = wake
    try:
        while True:
            try:
                if turn_id in _quota_pauses:
                    _quota_pauses[turn_id]["state"] = "resuming"
                result = await factory()
                if started is not None:
                    finished = dict(_quota_pauses.get(turn_id, {}))
                    finished.update({
                        "state": "resumed",
                        "resumed_at": datetime.datetime.now().astimezone().isoformat(),
                        "duration_seconds": round(time.monotonic() - started, 3),
                    })
                    _last_quota_pause = finished
                return result
            except CodexError as error:
                metadata = quota_metadata(str(error))
                if metadata is None:
                    raise
                qerror = UsageLimitError(str(error), metadata)
                if QUOTA_MAX_WAIT <= 0:
                    raise qerror
                now_mono = time.monotonic()
                if started is None:
                    started = now_mono
                    started_at = datetime.datetime.now().astimezone().isoformat()
                remaining = QUOTA_MAX_WAIT - (now_mono - started)
                if remaining <= 0:
                    exhausted = dict(_quota_pauses.get(turn_id, {}))
                    exhausted.update({
                        "state": "exhausted",
                        "ended_at": datetime.datetime.now().astimezone().isoformat(),
                        "duration_seconds": round(now_mono - started, 3),
                    })
                    _last_quota_pause = exhausted
                    raise qerror
                delay = metadata.get("retry_after")
                if delay is None:
                    delay = min(QUOTA_BACKOFF * (2 ** min(retries, 20)),
                                QUOTA_MAX_BACKOFF)
                delay = min(max(0.05, float(delay)), remaining)
                retry_at = datetime.datetime.now().astimezone() + \
                    datetime.timedelta(seconds=delay)
                state = {
                    "state": "paused_quota",
                    "reason": "usage_limit",
                    "paused_at": started_at,
                    "retry_at": retry_at.isoformat(),
                    "retry": retries + 1,
                }
                _quota_pauses[turn_id] = state
                _last_quota_pause = dict(state)
                log.warning("usage limit; pausing turn %.1fs (retry %d)",
                            delay, retries + 1)
                try:
                    await asyncio.wait_for(wake.wait(), timeout=delay)
                    wake.clear()
                    log.warning("operator requested immediate quota retry")
                except asyncio.TimeoutError:
                    pass
                retries += 1
    finally:
        _quota_pauses.pop(turn_id, None)
        _quota_wakes.pop(turn_id, None)


def request_quota_retry():
    """Wake quota-paused requests so they recheck the account immediately."""
    now = datetime.datetime.now().astimezone().isoformat()
    woken = 0
    for turn_id, wake in list(_quota_wakes.items()):
        pause = _quota_pauses.get(turn_id)
        if pause is None or pause.get("state") != "paused_quota":
            continue
        pause["state"] = "resuming"
        pause["retry_at"] = now
        pause["operator_retry_at"] = now
        wake.set()
        woken += 1
    if woken:
        log.warning("SIGHUP: retrying %d quota-paused turn(s)", woken)
    else:
        log.info("SIGHUP: no quota-paused turns to retry")
    return woken


def child_env():
    env = dict(os.environ)
    env.pop("OPENAI_API_KEY", None)      # never bill the API by accident
    home = os.environ.get("CODEX_GATE_CODEX_HOME")
    if home:
        env["CODEX_HOME"] = home
    return env


def check_codex_auth():
    """Refuse readiness when the CLI cannot use a ChatGPT login."""
    if MOCK:
        return
    try:
        result = subprocess.run(
            [CODEX_BIN, "login", "status"], env=child_env(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=10, check=False)
    except FileNotFoundError:
        raise SystemExit("codex-gate: codex CLI not found (%s)" % CODEX_BIN)
    except subprocess.TimeoutExpired:
        raise SystemExit("codex-gate: timed out checking codex login status")
    status = (result.stdout + "\n" + result.stderr).strip()
    if result.returncode != 0:
        detail = status.splitlines()
        detail = detail[-1] if detail else "not logged in"
        raise SystemExit("codex-gate: codex login unavailable: %s" % detail)
    if "chatgpt" not in status.lower():
        raise SystemExit(
            "codex-gate: Codex is not logged in with ChatGPT; run `codex login` "
            "or explicitly allow API-key mode with CODEX_GATE_ALLOW_API_KEY=1")


def unknown_flag(stderr):
    """The flag a clap usage error is complaining about, if it's one of ours."""
    for flag in OPTIONAL_FLAGS - _dropped_flags:
        if ("unexpected argument '%s'" % flag) in stderr or \
           ("unexpected argument \"%s\"" % flag) in stderr or \
           ("unrecognized" in stderr and flag in stderr):
            return flag
    return None


def build_argv(model, schema_path, last_message_path, prompt):
    # profile_flags() carries the sandbox, the pinned feature disables and the
    # "read no configuration of your own" flags. Native CLI shell access is
    # among them because it competes with the virtual caller-tool protocol:
    # the model otherwise tries to read the gateway VM instead of requesting
    # Veltro's read tool. None of these are droppable — a build that does not
    # understand one must fail loudly rather than run without it.
    argv = [CODEX_BIN, "exec"] + profile_flags() + \
        ["-c", "developer_instructions=" + json.dumps(ADAPTER_INSTRUCTIONS)]
    def add(flag, value=None):
        if flag in _dropped_flags:
            return
        if value is None and flag not in ("--json", "--skip-git-repo-check"):
            return                      # optional value absent — skip the flag
        argv.append(flag)
        if value is not None:
            argv.append(value)
    add("--json")
    add("--skip-git-repo-check")
    add("--cd", WORKDIR)
    add("--output-last-message", last_message_path)
    add("--output-schema", schema_path)
    # "default" is the stable model-picker entry. Codex model names evolve;
    # omitting -m lets the installed CLI choose its configured current model.
    if model and model != "default":
        argv += ["-m", model]
    argv += shlex.split(os.environ.get("CODEX_GATE_EXEC_ARGS", ""))
    argv.append(prompt if PROMPT_ARGV else "-")
    return argv


def parse_events(stdout):
    """(agent_text, usage_tokens, error).  Tolerates both `codex exec --json`
    event dialects: the current {"type": "item.completed", "item": {...}}
    stream and the older {"msg": {"type": ...}} one."""
    text_parts = []
    usage = 0
    error = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        msg = ev.get("msg") if isinstance(ev.get("msg"), dict) else ev
        kind = msg.get("type") or ev.get("type") or ""
        if kind in ("item.completed", "item.updated"):
            item = msg.get("item") or {}
            if item.get("type") in ("agent_message", "assistant_message"):
                t = item.get("text") or item.get("message") or ""
                if t:
                    text_parts.append(t)
            continue
        if kind == "agent_message":
            t = msg.get("message") or msg.get("text") or ""
            if t:
                text_parts.append(t)
        elif kind in ("turn.completed", "token_count", "turn_complete"):
            u = msg.get("usage") or msg.get("info") or {}
            if isinstance(u, dict):
                usage = (int(u.get("input_tokens", 0) or 0) +
                         int(u.get("output_tokens", 0) or 0)) or usage
        elif kind in ("error", "turn.failed", "stream_error"):
            err = msg.get("error")
            if isinstance(err, dict):
                err = err.get("message")
            error = err or msg.get("message") or "codex reported an error"
    return "\n".join(text_parts), usage, error


async def run_codex(model, prompt, schema):
    """One `codex exec`.  Returns (final_text, usage_tokens)."""
    global _home_inventory_cache
    tmpdir = tempfile.mkdtemp(prefix="codex-gate-")
    schema_path = os.path.join(tmpdir, "schema.json")
    last_path = os.path.join(tmpdir, "last-message.txt")
    if schema is not None:
        with open(schema_path, "w") as f:
            json.dump(schema, f)
    else:
        schema_path = None

    # Each usage error names one unknown flag, so a CLI that rejects two of
    # them needs two retries.  Bounded by the number of droppable flags —
    # the loop only continues when an attempt actually dropped something.
    for _ in range(len(OPTIONAL_FLAGS) + 1):
        argv = build_argv(model, schema_path, last_path, prompt)
        log.debug("exec: %s", " ".join(argv))
        try:
            process_group = {"start_new_session": True} if os.name == "posix" else {}
            proc = await asyncio.create_subprocess_exec(
                *argv, cwd=WORKDIR, env=child_env(),
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                **process_group)
        except FileNotFoundError:
            raise CodexError("codex CLI not found (%s) — install it or set "
                             "CODEX_GATE_BIN" % CODEX_BIN)
        try:
            out, err = await communicate_with_deadlines(proc, prompt.encode())
        except asyncio.CancelledError:
            await kill_process_group(proc)
            raise
        finally:
            # The CLI may have changed its isolated home even on failure.
            _home_inventory_cache = None

        stdout = out.decode("utf-8", "replace")
        stderr = err.decode("utf-8", "replace")
        if proc.returncode != 0:
            flag = unknown_flag(stderr)
            if flag:
                log.warning("codex CLI rejects %s — dropping it", flag)
                _dropped_flags.add(flag)
                if flag == "--output-schema":
                    schema_path = None
                continue
            _, _, event_err = parse_events(stdout)
            tail = stderr.strip().splitlines()[-1] if stderr.strip() else ""
            raise CodexError(event_err or tail or
                             "codex exec failed (rc=%d)" % proc.returncode)

        text, usage, event_err = parse_events(stdout)
        if event_err and not text:
            raise CodexError(event_err)
        # --output-last-message is the authoritative final message when the
        # CLI supports it; the event stream is the fallback.
        try:
            with open(last_path) as f:
                last = f.read()
            if last.strip():
                text = last
        except OSError:
            pass
        if not text.strip() and stderr.strip():
            raise CodexError(stderr.strip().splitlines()[-1])
        return text, usage
    raise CodexError("codex exec failed")


async def capture_output(stream, chunks, progress):
    while True:
        data = await stream.read(8192)
        if not data:
            return
        chunks.append(data)
        progress.put_nowait(1)


async def feed_input(stream, data):
    try:
        stream.write(data)
        await stream.drain()
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        stream.close()


async def kill_process_group(proc):
    if proc.returncode is None:
        try:
            if os.name == "posix":
                os.killpg(proc.pid, signal.SIGKILL)
            else:
                proc.kill()
        except OSError:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
    await proc.wait()


async def communicate_with_deadlines(proc, input_data):
    """Capture CLI output while enforcing total and no-output deadlines."""
    out_chunks, err_chunks = [], []
    progress = asyncio.Queue()
    readers = [
        asyncio.create_task(capture_output(proc.stdout, out_chunks, progress)),
        asyncio.create_task(capture_output(proc.stderr, err_chunks, progress)),
    ]
    loop = asyncio.get_running_loop()
    total_deadline = loop.time() + EXEC_TIMEOUT
    idle_deadline = loop.time() + IDLE_TIMEOUT if IDLE_TIMEOUT > 0 else total_deadline
    input_task = asyncio.create_task(feed_input(proc.stdin, input_data))
    wait_task = asyncio.create_task(proc.wait())
    progress_task = None
    try:
        while not wait_task.done():
            now = loop.time()
            remaining = min(total_deadline - now, idle_deadline - now)
            if remaining <= 0:
                break
            progress_task = asyncio.create_task(progress.get())
            done, _ = await asyncio.wait(
                (wait_task, progress_task), timeout=remaining,
                return_when=asyncio.FIRST_COMPLETED)
            if progress_task in done:
                idle_deadline = loop.time() + IDLE_TIMEOUT
                progress_task = None
            elif progress_task is not None:
                progress_task.cancel()
                progress_task = None

        if not wait_task.done():
            now = loop.time()
            idle = IDLE_TIMEOUT > 0 and idle_deadline <= now and total_deadline > now
            await kill_process_group(proc)
            if idle:
                raise CodexError(
                    "codex exec produced no output for CODEX_GATE_IDLE_TIMEOUT (%.0fs)"
                    % IDLE_TIMEOUT)
            raise CodexError("codex exec exceeded CODEX_GATE_TIMEOUT (%.0fs)"
                             % EXEC_TIMEOUT)
        await asyncio.gather(*readers)
        return b"".join(out_chunks), b"".join(err_chunks)
    finally:
        if progress_task is not None:
            progress_task.cancel()
        if not wait_task.done():
            wait_task.cancel()
        if not input_task.done():
            input_task.cancel()
        for task in readers:
            if not task.done():
                task.cancel()
        await asyncio.gather(input_task, *readers, return_exceptions=True)


async def codex_turn(model, system_prompt, prompt, tooldefs):
    """(content, [(name, args)], usage_tokens)."""
    full = prompt
    instructions = system_prompt
    if tooldefs:
        instructions = (instructions + "\n\n" if instructions else "") + \
            tool_instructions(tooldefs)
    if instructions:
        full = ("<system_instructions>\n" + instructions +
                "\n</system_instructions>\n\n" + prompt)

    async with _sem:
        text, usage = await run_codex(model, full, TOOL_SCHEMA if tooldefs else None)

    if tooldefs:
        content, calls = parse_tool_reply(text)
        return content, calls, usage
    return text, [], usage


# ── mock backend (CODEX_GATE_MOCK=1) ───────────────────────────────

async def mock_turn(model, system_prompt, prompt, tooldefs, trailing_tools):
    """Deterministic stand-in mirroring claude-gate's mock, adapted to this
    gate's stateless shape: tool results arrive in the request, not on a
    held turn.  `MOCK_TOOL_CALL <name> <json>` triggers one tool call."""
    global _mock_errors_remaining
    selected = not MOCK_ERROR_SYSTEM_MATCH or \
        MOCK_ERROR_SYSTEM_MATCH in system_prompt
    if MOCK_ERROR and selected and _mock_errors_remaining != 0:
        if _mock_errors_remaining > 0:
            _mock_errors_remaining -= 1
        raise CodexError(MOCK_ERROR)
    delay = float(os.environ.get("CODEX_GATE_MOCK_DELAY", "0"))
    if delay > 0:
        await asyncio.sleep(delay)
    if trailing_tools:
        content = trailing_tools[-1].get("content") or ""
        suffix = " (is_error)" if is_error_result(content) else ""
        return "TOOL_RESULT_WAS: %s%s" % (content, suffix), [], 7
    if tooldefs and "MOCK_TOOL_CALL" in prompt:
        parts = prompt.split("MOCK_TOOL_CALL", 1)[1].strip().split(" ", 1)
        name = parts[0]
        try:
            args = json.loads(parts[1]) if len(parts) > 1 else {}
        except Exception:
            args = {}
        return "", [(name, args)], 3
    return "MOCK_REPLY: " + prompt[-200:], [], 5


def is_error_result(content):
    return content.startswith("Error:") or content.startswith("error:")


# ── HTTP handlers ──────────────────────────────────────────────────

async def chat_completions(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response(
            {"error": {"message": "invalid JSON body"}}, status=400)

    messages = body.get("messages") or []
    tooldefs = body.get("tools") or []
    stream = bool(body.get("stream"))
    model = body.get("model") or DEFAULT_MODEL

    system_prompt, history = split_messages(messages)
    prompt = render_prompt(history)
    if not prompt:
        return web.json_response(
            {"error": {"message": "no user content in messages"}}, status=400)

    trailing = [m for m in history if m.get("role") == "tool"]
    def turn_factory():
        if MOCK:
            return mock_turn(model, system_prompt, prompt, tooldefs, trailing)
        return codex_turn(model, system_prompt, prompt, tooldefs)

    turn = run_with_quota_recovery(turn_factory)

    stream_response = None
    task = None
    try:
        if stream:
            # Commit the HTTP response before invoking Codex, then keep the
            # caller's per-read watchdog alive while a long reasoning turn is
            # making progress inside the CLI. SSE comments are protocol-valid
            # and ignored by OpenAI clients.
            stream_response = web.StreamResponse(headers={
                "Content-Type": "text/event-stream",
                "Cache-Control": "no-cache",
            })
            await stream_response.prepare(request)
            task = asyncio.create_task(turn)
            while not task.done():
                done, _ = await asyncio.wait((task,), timeout=HEARTBEAT)
                if not done:
                    await stream_response.write(b": codex-gate working\n\n")
            content, calls, usage = await task
        else:
            content, calls, usage = await turn
    except CodexError as e:
        log.error("turn failed: %s", e)
        quota = e if isinstance(e, UsageLimitError) else None
        if stream_response is not None:
            if quota is not None:
                await stream_response.write(
                    b"data: " + json.dumps(quota_error_body(quota)).encode() +
                    b"\n\ndata: [DONE]\n\n")
                await stream_response.write_eof()
                return stream_response
            return await respond(request, model, "ERROR: codex-gate: %s" % e,
                                 [], 0, True, stream_response)
        if quota is not None:
            return web.json_response(quota_error_body(quota), status=429)
        return web.json_response(
            {"error": {"message": "codex-gate: %s" % e, "type": "gate_error"}},
            status=502)
    except (ConnectionResetError, asyncio.CancelledError):
        if task is not None and not task.done():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        raise
    except Exception as e:                              # noqa: BLE001
        log.exception("turn failed")
        if stream_response is not None:
            return await respond(request, model, "ERROR: codex-gate: %s" % e,
                                 [], 0, True, stream_response)
        return web.json_response(
            {"error": {"message": "codex-gate: %s" % e, "type": "gate_error"}},
            status=502)

    return await respond(request, model, content, calls, usage, stream,
                         stream_response)


async def models(request):
    data = [{"id": m, "object": "model", "owned_by": "openai"}
            for m in ADVERTISED_MODELS]
    return web.json_response({"object": "list", "data": data})


async def health(request):
    states = {pause.get("state") for pause in _quota_pauses.values()}
    state = ("paused_quota" if "paused_quota" in states else
             "resuming" if "resuming" in states else "ready")
    body = {
        "status": "ok",
        "backend": "mock" if MOCK else "codex-cli",
        # No live CLI session spans a tool round-trip here (see the module
        # comment); the key stays for parity with claude-gate's /health.
        "held_turns": 0,
        # Protocol turns are stateless. CODEX_HOME is deliberately isolated,
        # but the CLI may still write operational state there between turns.
        "stateless": True,
        "session_stateless": True,
        "quota_recovery": QUOTA_MAX_WAIT > 0,
        "turn_timeout_seconds": EXEC_TIMEOUT,
        "idle_timeout_seconds": IDLE_TIMEOUT,
        "state": state,
        "quota": {
            "paused_turns": len(_quota_pauses),
            "retry_at": min((p["retry_at"] for p in _quota_pauses.values()),
                            default=None),
            "last_pause": _last_quota_pause,
            "max_wait_seconds": QUOTA_MAX_WAIT,
        },
    }
    # The pinned CLI surface (INFR-413). A campaign records this verbatim, and
    # the external escape-room harness refuses to start a trial against a
    # gateway that is not running the profile the scenario asked for.
    body.update(PROFILE)
    home = os.environ.get("CODEX_GATE_CODEX_HOME")
    if home and not MOCK:
        body["codex_home_current"] = codex_home_summary(home)
    return web.json_response(body)


def main():
    logging.basicConfig(
        level=logging.DEBUG if os.environ.get("CODEX_GATE_DEBUG") else logging.INFO,
        format="codex-gate: %(levelname)s %(message)s")

    # `codex_gate.py --inventory [HOME]` — the post-campaign account of the
    # model-side state the CLI created for itself (INFR-413). Not a server
    # mode; it prints and exits.
    argv = sys.argv[1:]
    if argv and argv[0] == "--inventory":
        home = (argv[1] if len(argv) > 1 else
                os.environ.get("CODEX_GATE_CODEX_HOME") or
                os.environ.get("CODEX_HOME") or
                os.path.expanduser("~/.codex"))
        print(json.dumps(codex_home_inventory(home), indent=2))
        return

    if argv and argv[0] == "--prepare-home":
        if len(argv) != 3:
            raise SystemExit(
                "usage: codex_gate.py --prepare-home LOGIN_HOME CAMPAIGN_HOME")
        destination = prepare_codex_home(argv[1], argv[2])
        print("codex-gate: prepared auth-only CODEX_HOME at %s" % destination)
        return

    if os.environ.get("OPENAI_API_KEY") and not MOCK \
            and os.environ.get("CODEX_GATE_ALLOW_API_KEY") != "1":
        raise SystemExit(
            "codex-gate: OPENAI_API_KEY is set — the CLI may bill the API "
            "instead of your ChatGPT plan. Unset it (serve-codex-gate.sh "
            "does) or set CODEX_GATE_ALLOW_API_KEY=1 to override.")

    # An isolated Codex home is only isolated if nothing else got in. Checked
    # before the first request, because the CLI populates the directory itself
    # once one arrives and the baseline is gone (INFR-413).
    home = os.environ.get("CODEX_GATE_CODEX_HOME")
    if home and not MOCK:
        violations = codex_home_violations(home, home_allowlist())
        if violations:
            raise SystemExit(
                "codex-gate: refusing to serve — %s holds configuration this "
                "gateway did not sanction:\n  %s\nRemove it, or widen "
                "CODEX_GATE_HOME_ALLOW deliberately."
                % (home, "\n  ".join(violations)))

    allow_api_key = os.environ.get("OPENAI_API_KEY") and \
        os.environ.get("CODEX_GATE_ALLOW_API_KEY") == "1"
    if not allow_api_key:
        check_codex_auth()

    PROFILE.update(gate_profile())
    if not MOCK:
        log.info("codex %s, %s, %d features disabled",
                 PROFILE.get("codex_version"),
                 "hardened" if HARDEN else "NOT hardened",
                 len(PROFILE.get("disabled_features", [])))

    if not MOCK:
        try:
            os.makedirs(WORKDIR, exist_ok=True)
        except OSError as e:
            raise SystemExit("codex-gate: cannot create workdir %s: %s"
                             % (WORKDIR, e))

    app = web.Application()
    app.router.add_post("/v1/chat/completions", chat_completions)
    app.router.add_get("/v1/models", models)
    app.router.add_get("/health", health)

    async def make_sem(app):
        global _sem
        _sem = asyncio.Semaphore(CONCURRENCY)
        if hasattr(signal, "SIGHUP"):
            try:
                asyncio.get_running_loop().add_signal_handler(
                    signal.SIGHUP, request_quota_retry)
            except (NotImplementedError, RuntimeError):
                log.warning("SIGHUP quota retry is unavailable on this platform")
    app.on_startup.append(make_sem)

    log.info("listening on http://%s:%d/v1 (%s backend)",
             HOST, PORT, "mock" if MOCK else "codex-cli")
    web.run_app(app, host=HOST, port=PORT, print=None)


if __name__ == "__main__":
    main()
