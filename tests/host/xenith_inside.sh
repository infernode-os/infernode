# xenith_inside.sh — run an Inferno sh script inside a headless Xenith.
#
# Source it after common.sh, then:
#
#	xenith_inside name /tests/inferno/script.sh
#
# The script sees /mnt/xenith. Its output lines starting PASS or FAIL
# are printed; the function returns 0 if it printed "ALL PASS", 77 if
# Xenith cannot run here (no emu, a headless build, Xenith not built),
# and 1 otherwise, printing the rest of the output.
#
# Xenith forks its namespace, so only commands it runs itself see
# /mnt/xenith. It is handed a dump file whose one external-command
# entry ("e", re-run on load as Acme does) runs the script, reporting
# on the emulator's own console. Xenith runs under the SDL dummy
# driver, so the SDL GUI emulator is needed.

xenith_inside() {
    _name=$1
    _script=$2
    [ -x "$EMU" ] || { echo "$_name: SKIP (no emu)"; return 77; }
    if command -v nm >/dev/null 2>&1; then
        _syms=$(nm "$EMU" 2>/dev/null)
        if [ -n "$_syms" ] && ! printf '%s\n' "$_syms" | grep -q sdl3_mainloop; then
            echo "$_name: SKIP (headless emulator)"; return 77
        fi
    fi
    [ -f "$ROOT/dis/xenith.dis" ] || { echo "$_name: SKIP (Xenith not built)"; return 77; }

    # Xenith's temporary files go in /tmp (gitignored; a fresh clone
    # has none)
    mkdir -p "$ROOT/tmp"
    _dir=$(mktemp -d "$ROOT/.$_name.XXXXXX")
    _d=${_dir##*/}
    {
        echo /
        echo
        echo
        printf '%11d \n' 0
        printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0
        echo
        echo /
        echo "sh /$_d/run"
    } > "$_dir/dump"
    {
        echo "sh $_script >'#c/cons' >[2=1]"
        echo "echo halt >'#c/sysctl'"
    } > "$_dir/run"

    _out=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c0 -g800x600 -r"$ROOT" /dis/sh.dis -c "
load std
xenith -l /$_d/dump" 2>&1)
    rm -rf "$_dir"

    printf '%s\n' "$_out" | grep -E '^(PASS|FAIL|ALL PASS)'
    if printf '%s\n' "$_out" | grep -q '^ALL PASS'; then
        return 0
    fi
    echo "FAIL: $_name"
    printf '%s\n' "$_out" | grep -vE '^(PASS|FAIL)' | sed 's/^/    /'
    return 1
}
