#!/bin/bash
#
# compile-limbo.sh — compile a Limbo source file to the path declared
# in the module's PATH constant.  The whole point: eliminate the
# manual `-o <path>` choice that has repeatedly cost us debug sessions
# (latest: INFR-28 file-browser theme propagation, where every "fix"
# landed in dis/cmd/lucictx.dis while emu loaded /dis/lucictx.dis).
#
# Usage:
#   tools/compile-limbo.sh appl/cmd/lucictx.b [appl/cmd/another.b ...]
#
# For each input file:
#   1. Parse it to find `implement <Foo>;`
#   2. Find `<Foo>: module { ... PATH: con "/dis/...path..."; ... }`
#   3. Run limbo with -o <ROOT>/dis/<...path...> and the include flags
#      the file needs (auto-derived from its `include` statements).
#   4. Print "OK <source> -> <output>" on success.
#
# If the source has no `implement` (a module-interface file) or no PATH
# constant, this prints a warning and falls back to mk's behaviour
# (skip — let `mk` handle it).
#
# Use this instead of `limbo -o ...` directly.  CLAUDE.md and the
# pre-commit hook both refer to this script as the canonical compile
# entry point.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIMBO_BIN=""

# Find a native limbo compiler.  Prefer the platform-appropriate one
# already shipped in MacOSX/<arch>/bin or Linux/<arch>/bin.
case "$(uname -s)-$(uname -m)" in
	Darwin-arm64)    LIMBO_BIN="$ROOT/MacOSX/arm64/bin/limbo" ;;
	Darwin-x86_64)   LIMBO_BIN="$ROOT/MacOSX/amd64/bin/limbo" ;;
	Linux-aarch64)   LIMBO_BIN="$ROOT/Linux/arm64/bin/limbo" ;;
	Linux-x86_64)    LIMBO_BIN="$ROOT/Linux/amd64/bin/limbo" ;;
	MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64)
	                 LIMBO_BIN="$ROOT/Nt/amd64/bin/limbo.exe" ;;
esac

if [[ -z "$LIMBO_BIN" || ! -x "$LIMBO_BIN" ]]; then
	# Fallback: PATH lookup.
	LIMBO_BIN="$(command -v limbo 2>/dev/null || true)"
fi

if [[ -z "$LIMBO_BIN" ]]; then
	echo "compile-limbo: no limbo compiler found — build the native tools first" >&2
	exit 2
fi

scan_module_path() {
	# Print the PATH constant of the module the file IMPLEMENTS.
	# See tools/verify-dis-paths.sh for matching rules — kept in sync.
	awk '
		/^implement[[:space:]]+[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/ {
			match($0, /[A-Za-z][A-Za-z0-9_]*[[:space:]]*;/)
			impl = substr($0, RSTART, RLENGTH)
			sub(/[[:space:]]*;.*$/, "", impl)
		}
		impl != "" && $0 ~ ("^" impl "[[:space:]]*:[[:space:]]*module") { in_mod = 1; next }
		in_mod && /PATH[[:space:]]*:[[:space:]]*con[[:space:]]*"\/dis\// {
			match($0, /"\/dis\/[^"]+"/)
			if(RSTART > 0) {
				p = substr($0, RSTART+1, RLENGTH-2)
				print p
				exit
			}
		}
		in_mod && /^[[:space:]]*}/ { in_mod = 0 }
	' "$1"
}

derive_includes() {
	# Build the -I flag set this file needs.  Default to module/.
	# Add appl/<subdir>/ for any include that resolves there.
	local src="$1"
	local includes="-I$ROOT/module"
	local extra=""
	while IFS= read -r inc; do
		# Search known module subdirs; add to -I if the include exists there.
		for sub in appl/veltro appl/xenith appl/charon; do
			if [[ -f "$ROOT/$sub/$inc" ]]; then
				case " $extra " in
					*" -I$ROOT/$sub "*) ;;
					*) extra="$extra -I$ROOT/$sub" ;;
				esac
				break
			fi
		done
	done < <(awk '/include[[:space:]]+"/ {
		match($0, /"[^"]+"/)
		if(RSTART > 0) print substr($0, RSTART+1, RLENGTH-2)
	}' "$src")
	echo "$includes$extra"
}

if [[ $# -lt 1 ]]; then
	echo "usage: $0 <source.b> [<source.b> ...]" >&2
	exit 2
fi

rc=0
for src in "$@"; do
	if [[ ! -f "$src" ]]; then
		echo "compile-limbo: $src: no such file" >&2
		rc=1
		continue
	fi

	disrel="$(scan_module_path "$src" || true)"
	if [[ -z "$disrel" ]]; then
		echo "compile-limbo: $src: no IMPLEMENT or PATH constant; skipping" >&2
		echo "  (use mk for files that don't declare their own load path)" >&2
		continue
	fi

	# Resolve /dis/... to a path inside the source tree.
	out="$ROOT/${disrel#/}"
	mkdir -p "$(dirname "$out")"

	flags="$(derive_includes "$src")"
	# shellcheck disable=SC2086
	if "$LIMBO_BIN" $flags -gw -o "$out" "$src"; then
		echo "OK $src -> $out"
	else
		echo "FAIL $src" >&2
		rc=1
	fi
done

exit $rc
