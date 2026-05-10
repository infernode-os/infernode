#!/bin/bash
# Assemble an unsigned dev InferNode.app bundle from the working tree.
# Mirrors the production release.yml steps minus codesign + notarize +
# strip. Intended for local testing of harness changes against the
# Hephaestus-served LLM via 9P-remote.
#
# Output: /tmp/InferNode-dev.app
#
# Usage:
#   ./build-dev-bundle.sh
#   open --stdout /tmp/infernode-dev.out --stderr /tmp/infernode-dev.err /tmp/InferNode-dev.app
#
# Secstore / wallet state lives in ~/.infernode regardless of which
# bundle launches it, so config persists across the production
# /Applications/InferNode.app and this dev bundle.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-/tmp/InferNode-dev.app}"

CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

[ -x "$ROOT/emu/MacOSX/o.emu" ] || {
	echo "build-dev-bundle: emu not found — run ./build-macos-sdl3.sh first" >&2
	exit 1
}

echo "Assembling dev bundle: $APP"
rm -rf "$APP"
cp -a "$ROOT/MacOSX/InferNode.app" "$APP"

mkdir -p "$MACOS" "$RESOURCES"

# Emulator binary (the SDL3 build links homebrew SDL3 by absolute path,
# so we don't need to copy the dylib for local dev).
cp "$ROOT/emu/MacOSX/o.emu" "$MACOS/emu"

# Native tools (some Limbo features call out to these).
mkdir -p "$MACOS/tools"
cp "$ROOT/MacOSX/arm64/bin/limbo" "$MACOS/tools/"
cp "$ROOT/MacOSX/arm64/bin/mk" "$MACOS/tools/"

# Runtime tree
for d in dis lib fonts module services locale usr mnt; do
	[ -d "$ROOT/$d" ] && cp -a "$ROOT/$d" "$RESOURCES/"
done
mkdir -p "$RESOURCES/tmp" "$RESOURCES/usr/inferno/secstore" "$RESOURCES/usr/inferno/tmp"

# Bundled default LLM config — gets overridden by the writable overlay
# at ~/.infernode/lib/ndb/llm.
cat > "$RESOURCES/lib/ndb/llm" << 'LLMCONF'
mode=local
backend=api
url=https://api.anthropic.com
model=claude-sonnet-4-5-20250929
dial=
LLMCONF

cp "$ROOT/mkconfig" "$RESOURCES/"
[ -d "$ROOT/mkfiles" ] && cp -a "$ROOT/mkfiles" "$RESOURCES/"

for f in LICENCE NOTICE TRADEMARK.md README.md QUICKSTART.md \
         build-macos-sdl3.sh build-macos-headless.sh makemk.sh; do
	[ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$RESOURCES/"
done

# Surface the build provenance — useful when comparing dev vs prod runs.
SHA=$(git -C "$ROOT" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
echo "Built from $ROOT @ $SHA at $(date -Iseconds)" > "$RESOURCES/dev-bundle-stamp.txt"

echo "Bundle assembled."
echo "  emu sha: $(shasum "$MACOS/emu" | cut -c1-8)"
echo "  llmclient.dis sha: $(shasum "$RESOURCES/dis/lib/llmclient.dis" | cut -c1-8)"
echo "  agentlib.dis sha: $(shasum "$RESOURCES/dis/veltro/agentlib.dis" | cut -c1-8)"
echo "  lucibridge.dis sha: $(shasum "$RESOURCES/dis/lucibridge.dis" | cut -c1-8)"
echo
echo "Launch with:"
echo "  open --stdout /tmp/infernode-dev.out --stderr /tmp/infernode-dev.err $APP"
