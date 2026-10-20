#!/bin/sh
#
# ask_test.sh — ask(1), a question put to the model at /mnt/llm, or to
# the command $llm names, with no model at all: commands and an llmsrv
# that is never asked stand in for one.
#
#	a command is given the instructions, a blank line and the question,
#	and its output is the answer; {system} in it takes the instructions;
#	-n names the model, -s gives the settings as attr=value words, each
#	unknown for a command; /mnt/llm's are the session's own files
#	(llmsrv, no call made); with nothing at /mnt/llm, ask says so.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "ask_test: SKIP (no emu)"; exit 77; }
[ -f "$ROOT/dis/llmsrv.dis" ] || { echo "ask_test: SKIP (dis not built)"; exit 77; }

fail=0
mkdir -p "$ROOT/tmp"
script=ask_test.$$
trap 'rm -rf "$ROOT/tmp/$script" "$ROOT/tmp/$script.sys" "$ROOT/tmp/$script.sys.mnt"' EXIT
printf 'Answer yes or no.\n' > "$ROOT/tmp/$script.sys"
cat > "$ROOT/tmp/$script" <<'S'
load std
sys=$1
echo '# command'
llm='cat > /dev/null; echo yes'
echo 'Is it raining?' | ask
echo '# command, with instructions'
llm=cat
echo 'Is it raining?' | ask $sys
echo '# command, {system}'
llm='cat > /dev/null; echo {system}'
echo 'Is it raining?' | ask $sys
echo '# command, -n and -s'
llm='cat > /dev/null; echo yes'
ask -n
ask -s
echo '# no model'
llm=()
mkdir -p $sys^.mnt/llm
bind $sys^.mnt /mnt
echo 'Is it raining?' | ask
echo '# status' $status
echo '# llm, -s'
llm=llm
llmsrv -b openai -u http://127.0.0.1:1/v1
ask -s
ask -n
echo '# done'
echo halt > /dev/sysctl
S
out=$(with_timeout 60 "$EMU" -c0 -r"$ROOT" /dis/sh.dis "/tmp/$script" "/tmp/$script.sys" 2>&1)
section() {
    printf '%s\n' "$out" | sed -n "/^# $1\$/,/^# /p"
}
check() {
    if section "$1" | grep -qx -- "$2"; then
        echo "PASS: $3"
    else
        echo "FAIL: $3"; section "$1" | sed 's/^/    /'; fail=1
    fi
}
check 'command' 'yes' 'a command'"'"'s output is the answer'
check 'command, with instructions' 'Answer yes or no.' 'the instructions come first'
check 'command, with instructions' 'Is it raining?' 'then the question'
check 'command, {system}' 'Answer yes or no.' '{system} takes the instructions'
check 'command, -n and -s' 'cat > /dev/null; echo yes' '-n names a command by itself'
check 'command, -n and -s' 'temperature=unknown maxtokens=unknown thinking=unknown' '-s: a command'"'"'s settings are unknown'
if section 'no model' | grep -q 'ask: no model at /mnt/llm'; then
    echo "PASS: with nothing at /mnt/llm, ask says so"
else
    echo "FAIL: with nothing at /mnt/llm, ask says so"; section 'no model' | sed 's/^/    /'; fail=1
fi
if section 'llm, -s' | grep -q '^temperature=[0-9.]* maxtokens=8192 thinking=[a-z0-9]*$'; then
    echo "PASS: -s: /mnt/llm's, from the session's files"
else
    echo "FAIL: -s: /mnt/llm's, from the session's files"; section 'llm, -s' | sed 's/^/    /'; fail=1
fi
check 'llm, -s' 'unknown' '-n: a server started with no model names it unknown'
exit $fail
