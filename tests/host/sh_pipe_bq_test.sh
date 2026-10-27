#!/bin/sh
#
# sh_pipe_bq_test.sh — a pipeline whose later command has a command
# substitution (`{...}, "{...}) ends.
#
# sh started a pipeline's commands from the left, finding each one's
# words just before starting it.  Finding them runs what is in `{...}
# and waits for it, reading sh's wait file, and that wait read and
# dropped the exit of any command of the pipeline already done.  The
# pipeline then waited for that exit for good: echo hi | grep `{echo
# hi} printed hi and sh never went on, in a script and in a shell
# window alike.  The words of every command are now found before any
# is started.
#
# Each case runs in a sh of its own, with a deadline, and must reach
# the line after it.  Runs on any emulator build, headless included.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "sh_pipe_bq_test: SKIP (no emu)"; exit 77; }

dir=$(mktemp -d "$ROOT/.sh_pipe_bq.XXXXXX")
trap 'rm -rf "$dir"' EXIT
name=${dir##*/}

fail=0
n=0
# case description, the line, what its output must hold
check() {
    n=$((n + 1))
    printf '%s\necho reached the next line\necho halt > /dev/sysctl\n' "$2" > "$dir/c$n.sh"
    out=$(with_timeout 20 "$EMU" -c0 -r"$ROOT" /dis/sh.dis "/$name/c$n.sh" 2>&1)
    if ! printf '%s\n' "$out" | grep -q 'reached the next line'; then
        echo "FAIL: $1: sh did not go on after: $2"
        printf '%s\n' "$out" | grep -v 'fsqid\|SDL' | sed 's/^/    /'
        fail=1
    elif [ -n "$3" ] && ! printf '%s\n' "$out" | grep -qF -- "$3"; then
        echo "FAIL: $1: no '$3' in:"
        printf '%s\n' "$out" | grep -v 'fsqid\|SDL' | sed 's/^/    /'
        fail=1
    else
        echo "PASS: $1"
    fi
}

check "\`{...} in the second command" 'echo hi | grep `{echo hi}' "hi"
check "\"{...} in the second command" 'echo hi | grep "{echo hi}' "hi"
check "\`{...} in the third command" 'echo a | cat | grep `{echo a}' "a"
check "the first command done long before" 'echo x | cat `{sleep 1; echo /dev/null}'
check "a substitution that fails" 'echo hi | grep `{nosuchcommand}'
check "a pipeline without one still runs" 'echo plain | cat' "plain"
exit $fail
