#!/bin/sh
#
# sh_noexec_script_test.sh — running a script that lacks the execute
# bit says so.
#
# sh runs a file that is not a Dis module as a script, by its #! line,
# when it is executable. One that is not used to fail with the error
# from looking for a module, "'./x.sh.dis' file does not exist", which
# reads as if the script were missing (Xenith's B2 shows the same).
# It must say the script is not executable, run once it is, and still
# fall through to a module later on the path.
#
# Runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "sh_noexec_script_test: SKIP (no emu)"; exit 77; }

dir=$(mktemp -d "$ROOT/.sh_noexec.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}

printf '#!/dis/sh\necho noexec ran\n' > "$dir/noexec.sh"
chmod 644 "$dir/noexec.sh"
printf '#!/dis/sh\necho script ran\n' > "$dir/runs.sh"
chmod 755 "$dir/runs.sh"
# a non-executable file named like a command, ahead of /dis on the path
printf 'not a script\n' > "$dir/echo"
chmod 644 "$dir/echo"

out=$(with_timeout 30 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "
cd /$name
noexec.sh
runs.sh
path=(. /dis)
echo path still searched
echo halt > /dev/sysctl" 2>&1)

fail=0
expect() {
    if printf '%s\n' "$out" | grep -qF -- "$2"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1: no '$2' in:"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=1
    fi
}
expect "a non-executable script is reported as such" "noexec.sh: './noexec.sh' is not executable"
expect "an executable script runs" "script ran"
expect "a non-executable file does not hide a command later on the path" "path still searched"
if printf '%s\n' "$out" | grep -q 'noexec.sh.dis'; then
    echo "FAIL: the error still names the module sh looked for"
    fail=1
fi
exit $fail
