#!/bin/sh
# Install git hooks from hooks/ into .git/hooks/
# Run once after clone: ./hooks/install.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKDIR="$ROOT/.git/hooks"

# Iterate every executable file in hooks/ except install.sh itself.
# Avoids having to update this loop each time a new hook is added.
for hook in "$ROOT"/hooks/*; do
    name="$(basename "$hook")"
    case "$name" in
        install.sh|*.md|*.txt) continue ;;
    esac
    [ -f "$hook" ] || continue
    cp "$hook" "$HOOKDIR/$name"
    chmod +x "$HOOKDIR/$name"
    echo "installed $name"
done
