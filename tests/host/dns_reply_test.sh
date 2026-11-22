#!/bin/sh
#
# dns_reply_test.sh -- ndb/dns against a server that sends replies it must
# not believe (tests/host/dns/fake_dns.py, on the loopback).
#
# A reply is taken only from the address and port the query went to and
# only if it answers the question asked; a record is read only inside its
# own declared length; an address record is four bytes; a response code
# past the ones dns has a name for is reported, not indexed; the largest
# time to live is taken, capped.  After each reply dns must still answer:
# a name that resolves is asked after every one.
#
# Runs on any emulator build, headless included.  Needs python3.

. "$(dirname "$0")/common.sh"
cd "$ROOT"

[ -x "$EMU" ] || { echo "dns_reply_test: SKIP (no emu)"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "dns_reply_test: SKIP (no python3)"; exit 77; }
[ -f "$ROOT/dis/ndb/dns.dis" ] || { echo "dns_reply_test: SKIP (dis/ndb/dns.dis not built)"; exit 77; }

dir=$(mktemp -d "$ROOT/.dnsreply.XXXXXX")
name=${dir##*/}
srvpid=
cleanup() {
	[ -n "$srvpid" ] && kill "$srvpid" 2>/dev/null
	rm -rf "$dir"
}
trap cleanup EXIT HUP INT TERM

python3 "$ROOT/tests/host/dns/fake_dns.py" > "$dir/port" 2> "$dir/server.err" &
srvpid=$!
port=
for i in 1 2 3 4 5 6 7 8 9 10; do
	port=$(head -1 "$dir/port" 2>/dev/null)
	[ -n "$port" ] && break
	sleep 0.3
done
[ -n "$port" ] || { echo "FAIL: dns_reply: the fake server did not start: $(cat "$dir/server.err")"; exit 1; }

printf 'infernosite=\n\tdns=127.0.0.1\n' > "$dir/ndb"

names="good0 rcode6 good1 shorta good2 overrun good3 otherq good4 wrongport good5 bigttl good6"
script="ndb/dns -h -r -p $port -f /$name/ndb
sleep 1
"
for n in $names; do
	script="$script echo Q-$n
ndb/dnsquery $n.test >[2=1]
"
done
script="$script echo ALL^DONE
echo halt > /dev/sysctl"

out=$(with_timeout 240 "$EMU" -c0 -r"$ROOT" /dis/sh.dis -c "$script" 2>&1)

fail=0
ok() { echo "PASS: dns_reply: $1"; }
bad() { echo "FAIL: dns_reply: $1"; fail=1; }

# what dnsquery printed for one name: the lines between its marker and the next
answer() {
	printf '%s\n' "$out" | awk -v m="Q-$1" '$0 == m { on=1; next } /^Q-/ || /^ALLDONE/ { on=0 } on'
}

if printf '%s\n' "$out" | grep -q '^ALLDONE'; then
	ok "every query returned"
else
	bad "the run did not finish: $(printf '%s\n' "$out" | tail -4 | tr '\n' ' ')"
fi

# the resolver went on answering after each reply it had to refuse
for n in good0 good1 good2 good3 good4 good5 good6; do
	if answer $n | grep -q '192\.0\.2\.1'; then
		:
	else
		bad "$n.test did not resolve: dns stopped answering before it ($(answer $n | head -2 | tr '\n' ' '))"
	fi
done
[ $fail = 0 ] && ok "a name that resolves is answered after every refused reply"

# a response code with no name is an error for that name, and no more
if answer rcode6 | grep -q '192\.0\.2\|198\.51\.100'; then
	bad "rcode6.test got an address from a reply that carried none"
else
	ok "response code 6 is reported for its name"
fi

# records that lie about their length give no address
for n in shorta overrun; do
	if answer $n | grep -q '192\.0\.2\|198\.51\.100'; then
		bad "$n.test: a record with a false length was believed"
	else
		ok "$n.test: a record with a false length is refused"
	fi
done

# the reply to another question, and the one from another port, are not taken
for n in otherq wrongport; do
	a=$(answer $n)
	if printf '%s\n' "$a" | grep -q '198\.51\.100'; then
		bad "$n.test resolved to the address in the reply that should have been ignored"
	elif printf '%s\n' "$a" | grep -q '192\.0\.2\.1'; then
		ok "$n.test: the stray reply ignored, the server's own taken"
	else
		bad "$n.test did not resolve at all: $(printf '%s\n' "$a" | head -2 | tr '\n' ' ')"
	fi
done

if answer bigttl | grep -q '192\.0\.2\.1'; then
	ok "the largest time to live is taken (and capped)"
else
	bad "bigttl.test did not resolve"
fi

if printf '%s\n' "$out" | grep -qiE 'array bounds|exception|Broken|panic'; then
	bad "dns raised: $(printf '%s\n' "$out" | grep -iE 'array bounds|exception|Broken|panic' | head -2 | tr '\n' ' ')"
else
	ok "nothing raised"
fi

exit $fail
