#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tcp=$root/os/ip/tcp.c

update=$(sed -n '/^update(Conv /,/^}/p' "$tcp")
seen=$(printf '%s\n' "$update" | grep -nF 'if(seg->update)' | cut -d: -f1)
ghost=$(printf '%s\n' "$update" | grep -nF 'if(seq_gt(seg->ack, tcb->snd.nxt))' | cut -d: -f1)
window=$(printf '%s\n' "$update" | grep -nF 'if(seq_gt(seg->seq, tcb->snd.wl1)' | cut -d: -f1)
dupack=$(printf '%s\n' "$update" | grep -nF '&& tcb->snd.wnd != 0' | cut -d: -f1)
if [ -z "$seen" ] || [ -z "$ghost" ] || [ -z "$window" ] || [ -z "$dupack" ] ||
   [ "$seen" -ge "$ghost" ] || [ "$ghost" -ge "$window" ]; then
	echo "FAIL: TCP ACK/window validation is incomplete or out of order" >&2
	exit 1
fi

output=$(sed -n '/^tcpoutput(Conv /,/^}/p' "$tcp")
if ! printf '%s\n' "$output" | grep -qF 'sent != 0 && (tcb->flags&RETRAN) == 0'; then
	echo "FAIL: a forced ACK can still transmit a zero-window probe" >&2
	exit 1
fi

input=$(sed -n '/^tcpiput(Proto /,/^}/p' "$tcp")
force=$(printf '%s\n' "$input" | grep -nF 'tcb->flags |= FORCE;' | head -1 | cut -d: -f1)
reseq=$(printf '%s\n' "$input" | grep -nF 'if(addreseq(' | cut -d: -f1)
if [ -z "$force" ] || [ -z "$reseq" ] || [ "$force" -ge "$reseq" ]; then
	echo "FAIL: out-of-order TCP input does not force its ACK before recovery" >&2
	exit 1
fi

if ! grep -q 'u32int[[:space:]]*wl1;' "$tcp"; then
	echo "FAIL: TCP does not retain the sequence number of its last window update" >&2
	exit 1
fi

if [ "$(grep -c 'tcph->update = 0;' "$tcp")" -ne 2 ]; then
	echo "FAIL: decoded IPv4/IPv6 TCP packets do not clear the update marker" >&2
	exit 1
fi

echo "PASS: TCP rejects ghost ACKs and isolates zero-window recovery"
