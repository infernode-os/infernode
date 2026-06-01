#!/bin/bash
#
# InferNode Setup — Desktop & PATH integration (Linux)
#
# Makes an extracted release easy to launch:
#   • installs a .desktop entry (app menu + dock) when a GUI is present
#   • symlinks the launcher onto $PATH as `infernode` (handy headless/SSH)
#
# The canonical entry is the shipped infernode.desktop; this script only
# rewrites its relative Exec/Icon to the absolute install path (which is not
# known until extraction). It auto-detects GUI (./infernode, Terminal=false)
# vs headless (./infernode-headless, Terminal=true), so the SAME script ships
# in every Linux release. Nothing in the release folder is modified.
#
# Usage:
#   ./setup-desktop.sh                 install icon (if GUI) + PATH symlink
#   ./setup-desktop.sh --no-path       icon only
#   ./setup-desktop.sh --no-icon       PATH symlink only (headless/server)
#   ./setup-desktop.sh --prefix DIR    symlink into DIR/bin (e.g. /usr/local)
#   ./setup-desktop.sh --uninstall     remove everything this script added
#   ./setup-desktop.sh --help

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SELF="$(basename "$0")"

# ── Colours / house-style helpers (match setup-linux.sh) ───────────
if [[ -t 1 ]]; then
    BOLD="\033[1m"; DIM="\033[2m"; GREEN="\033[32m"; YELLOW="\033[33m"
    RED="\033[31m"; CYAN="\033[36m"; RESET="\033[0m"
else
    BOLD="" DIM="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi
info()  { printf "${CYAN}▸${RESET} %s\n" "$*"; return 0; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$*"; return 0; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$*"; return 0; }
fail()  { printf "${RED}✗${RESET} %s\n" "$*"; exit 1; }

# Ownership checks for the PATH entry. A bare symlink does NOT work: the
# launcher resolves its emulator relative to $0's directory, so it must be
# invoked by its real absolute path. We install a tiny exec wrapper instead.
WRAP_MARKER="InferNode PATH wrapper"
is_inf_wrapper() { [ -f "$1" ] && grep -q "$WRAP_MARKER" "$1" 2>/dev/null; }
links_into_root() { [ -L "$1" ] && case "$(readlink "$1")" in "$ROOT"/*) return 0 ;; esac; return 1; }
# replaceable: safe to (over)write — absent, our wrapper, or an old symlink into THIS release
replaceable() { [ ! -e "$1" ] || is_inf_wrapper "$1" || links_into_root "$1"; }
# removable: belongs to THIS release — our wrapper pointing here, or a symlink into it
removable() { { [ -f "$1" ] && grep -q "$WRAP_MARKER -> $ROOT" "$1" 2>/dev/null; } || links_into_root "$1"; }

# ── Args ───────────────────────────────────────────────────────────
DO_ICON=1; DO_PATH=1; DO_UNINSTALL=0
BINDIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
while [ $# -gt 0 ]; do
    case "$1" in
        --help|-h) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --no-path) DO_PATH=0; shift ;;
        --no-icon) DO_ICON=0; shift ;;
        --uninstall) DO_UNINSTALL=1; shift ;;
        --prefix) [ $# -ge 2 ] || fail "--prefix needs a directory"; BINDIR="$2/bin"; shift 2 ;;
        --prefix=*) BINDIR="${1#--prefix=}/bin"; shift ;;
        *) fail "Unknown option: $1 (try --help)" ;;
    esac
done

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_ID="infernode"
DEST_DESKTOP="$APPS_DIR/$DESKTOP_ID.desktop"
LINK="$BINDIR/infernode"

# ── Detect which launcher this release ships ───────────────────────
if [ -x "$ROOT/infernode" ]; then
    EXEC="$ROOT/infernode"; TERMINAL="false"
elif [ -x "$ROOT/infernode-headless" ]; then
    EXEC="$ROOT/infernode-headless"; TERMINAL="true"
else
    fail "No infernode launcher in $ROOT (expected ./infernode or ./infernode-headless)"
fi

# ── Uninstall ──────────────────────────────────────────────────────
if [ "$DO_UNINSTALL" -eq 1 ]; then
    [ -f "$DEST_DESKTOP" ] && { rm -f "$DEST_DESKTOP"; ok "Removed $DEST_DESKTOP"; }
    if command -v gsettings >/dev/null 2>&1; then
        cur=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "")
        case "$cur" in *"'$DESKTOP_ID.desktop'"*)
            new=$(printf '%s' "$cur" | sed "s/, *'$DESKTOP_ID.desktop'//; s/'$DESKTOP_ID.desktop', *//; s/\['$DESKTOP_ID.desktop'\]/@as []/")
            gsettings set org.gnome.shell favorite-apps "$new" 2>/dev/null && ok "Unpinned from dock." || true ;;
        esac
    fi
    if [ -e "$LINK" ]; then
        if removable "$LINK"; then rm -f "$LINK"; ok "Removed launcher wrapper $LINK"
        else warn "Left $LINK alone — not ours."; fi
    fi
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
    exit 0
fi

printf "\n${BOLD}InferNode Setup — Desktop & PATH${RESET}\n\n"

# ── Desktop entry (reuse the shipped infernode.desktop as template) ─
if [ "$DO_ICON" -eq 1 ]; then
    ICON="$DESKTOP_ID"; [ -f "$ROOT/infernode.png" ] && ICON="$ROOT/infernode.png"
    mkdir -p "$APPS_DIR"
    SRC="$ROOT/infernode.desktop"
    if [ -f "$SRC" ]; then
        # Rewrite only the install-specific fields; keep Name/Comment/Categories.
        sed -e "s|^Exec=.*|Exec=$EXEC|" \
            -e "s|^Icon=.*|Icon=$ICON|" \
            -e "s|^Terminal=.*|Terminal=$TERMINAL|" \
            "$SRC" > "$DEST_DESKTOP"
        grep -q '^Path=' "$DEST_DESKTOP" || printf 'Path=%s\n' "$ROOT" >> "$DEST_DESKTOP"
    else
        # Headless tarballs may ship no .desktop; synthesise a minimal one.
        cat > "$DEST_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=InferNode
Comment=64-bit Inferno OS for embedded systems, servers, and AI agents
Exec=$EXEC
Icon=$ICON
Path=$ROOT
Terminal=$TERMINAL
Categories=Development;
EOF
    fi
    chmod 0644 "$DEST_DESKTOP"
    command -v desktop-file-validate >/dev/null 2>&1 && { desktop-file-validate "$DEST_DESKTOP" || warn "validation reported issues"; }
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" 2>/dev/null || true
    ok "Installed app entry: $DEST_DESKTOP (Terminal=$TERMINAL)"

    if command -v gsettings >/dev/null 2>&1 && gsettings writable org.gnome.shell favorite-apps >/dev/null 2>&1; then
        cur=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "@as []")
        case "$cur" in
            *"'$DESKTOP_ID.desktop'"*) info "Already pinned to the dock." ;;
            "@as []"|"[]") gsettings set org.gnome.shell favorite-apps "['$DESKTOP_ID.desktop']" && ok "Pinned to the dock." || true ;;
            *) gsettings set org.gnome.shell favorite-apps "$(printf '%s' "$cur" | sed "s|]$|, '$DESKTOP_ID.desktop']|")" && ok "Pinned to the dock." || true ;;
        esac
    fi
fi

# ── PATH wrapper (NOT a symlink — see note by the ownership helpers) ─
if [ "$DO_PATH" -eq 1 ]; then
    mkdir -p "$BINDIR"
    if ! replaceable "$LINK"; then
        warn "$LINK already exists and is not ours — skipping PATH install."
    else
        cat > "$LINK" <<EOF
#!/bin/sh
# $WRAP_MARKER -> $ROOT
exec "$EXEC" "\$@"
EOF
        chmod 0755 "$LINK"
        ok "Installed launcher wrapper: $LINK -> $EXEC"
        case ":$PATH:" in
            *":$BINDIR:"*) info "Run from anywhere with: infernode" ;;
            *) warn "$BINDIR is not on PATH. Add it:"; printf "    echo 'export PATH=\"%s:\$PATH\"' >> ~/.profile && . ~/.profile\n" "$BINDIR" ;;
        esac
    fi
fi

printf "\n${DIM}To remove: %s/%s --uninstall${RESET}\n" "$ROOT" "$SELF"
