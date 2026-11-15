#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EMU="${EMU:-$ROOT/emu/MacOSX/o.emu}"
[ -x "$EMU" ] || EMU="$ROOT/emu/Linux/o.emu"

[ -x "$EMU" ] || { echo "SKIP: no emulator found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 needed"; exit 0; }

PROBEDIR="$ROOT/tmp/dis-parser-bounds.$$"
mkdir -p "$PROBEDIR"
trap 'rm -rf "$PROBEDIR"' EXIT

python3 - "$PROBEDIR" <<'PY'
from pathlib import Path
import sys


def operand(value):
    if -64 <= value <= 63:
        return bytes([value & 0x7f])
    if -8192 <= value <= 8191:
        return bytes([0x80 | ((value >> 8) & 0x3f), value & 0xff])
    return bytes([0xc0 | ((value >> 24) & 0x3f)]) + (value & 0xffffff).to_bytes(3, "big")


out = Path(sys.argv[1])
header = b"".join(operand(v) for v in (819248, 0, 0, 0, 0, 1, 0, -1, -1))

# A type id equal to hsize used to write one pointer beyond Module.type.
(out / "type-id-oob.dis").write_bytes(header + operand(1))

# A declared one-byte type bitmap with no bitmap payload used to read past input.
(out / "type-map-truncated.dis").write_bytes(
    header + operand(0) + operand(0) + operand(1)
)

# Module data requires type descriptor zero.
(out / "missing-data-type.dis").write_bytes(
    b"".join(operand(v) for v in (819248, 0, 0, 0, 8, 0, 0, -1, -1))
)

data_header = b"".join(operand(v) for v in (819248, 0, 0, 0, 8, 1, 0, -1, -1))

# A type bitmap must not mark pointer words beyond the object allocation.
(out / "type-map-oob.dis").write_bytes(
    data_header + operand(0) + operand(8) + operand(1) + b"\x40"
)

pointer_type = data_header + operand(0) + operand(8) + operand(1) + b"\x80"

# Scalar initializers must not replace managed pointers with attacker data.
(out / "scalar-pointer.dis").write_bytes(
    pointer_type + b"\x21" + operand(0) + b"\x70\xc0\x14\x68"
)

# Reinitializing a managed pointer used to leak the first allocation.
(out / "duplicate-pointer.dis").write_bytes(
    pointer_type + b"\x31" + operand(0) + b"a" + b"\x31" + operand(0) + b"b"
)

scalar_header = b"".join(operand(v) for v in (819248, 0, 0, 0, 16, 1, 0, -1, -1))
scalar_type = scalar_header + operand(0) + operand(16) + operand(0)

# Typed stores at attacker-selected offsets must be naturally aligned.
(out / "unaligned-word.dis").write_bytes(
    scalar_type + b"\x21" + operand(1) + b"\x00\x00\x00\x01"
)

# One type and one export, no code and no data: the header, the type,
# the data's end, the module's name, then the export.
link_header = b"".join(operand(v) for v in (819248, 0, 0, 0, 0, 1, 1, -1, -1))
link_prefix = link_header + operand(0) + operand(8) + operand(0) + b"\x00" + b"m\x00"
sig = b"\x12\x34\x56\x78"

# pc -1 is how the compiler writes an exported global (".mp", no frame
# type). On a function it was linked as the instruction before the
# module's first.
(out / "link-pc-function.dis").write_bytes(
    link_prefix + operand(-1) + operand(0) + sig + b"init\x00"
)
(out / "link-pc-named.dis").write_bytes(
    link_prefix + operand(-1) + operand(-1) + sig + b"init\x00"
)
(out / "link-pc-typed.dis").write_bytes(
    link_prefix + operand(-1) + operand(0) + sig + b".mp\x00"
)
# and as the compiler writes it, it is still taken
(out / "link-mp.dis").write_bytes(
    link_prefix + operand(-1) + operand(-1) + sig + b".mp\x00"
)

# One instruction (a nop with no operands) and one exception handler over
# it. The handler's count says how many of its entries are for exception
# types and how many entries there are.
def handler(ne, n):
    h = b"".join(operand(v) for v in (819248, 32, 0, 1, 0, 0, 0, -1, -1))
    h += b"\x00\x1b"            # the instruction
    h += b"\x00"                 # no data
    h += b"m\x00"                # the module's name
    h += operand(1)              # one handler
    h += operand(0) + operand(0) + operand(1) + operand(-1)
    h += operand((ne << 16) | n)
    for i in range(n):
        h += b"e%d\x00" % i + operand(0)
    h += operand(-1)             # no default
    h += b"\x00"
    return h

# more entries for exception types than there are entries
(out / "handler-ne.dis").write_bytes(handler(2, 1))
(out / "handler-ne-none.dis").write_bytes(handler(1, 0))
(out / "handler-ok.dis").write_bytes(handler(1, 1))
PY

run_bad() {
	local module="$1" want="$2" out
	out=$("$EMU" -r "$ROOT" "/tmp/$(basename "$PROBEDIR")/$module" 2>&1 || true)
	if echo "$out" | grep -Eq 'panic|CORRUPT|segmentation|fault'; then
		echo "FAIL: $module crashed the emulator"
		echo "$out"
		exit 1
	fi
	if ! echo "$out" | grep -q "$want"; then
		echo "FAIL: $module did not report $want"
		echo "$out"
		exit 1
	fi
	echo "PASS: $module"
}

run_bad type-id-oob.dis "heap id range"
run_bad type-map-truncated.dis "implausible Dis file"
run_bad missing-data-type.dis "missing desc for mp"
run_bad type-map-oob.dis "implausible Dis file"
run_bad scalar-pointer.dis "bad word data range"
run_bad duplicate-pointer.dis "bad string data range"
run_bad unaligned-word.dis "bad word data range"
run_bad link-pc-function.dis "bad module link"
run_bad link-pc-named.dis "bad module link"
run_bad link-pc-typed.dis "bad module link"
run_bad handler-ne.dis "bad exception handler"
run_bad handler-ne-none.dis "bad exception handler"

# what the compiler writes is still loaded: these fail later, for having
# no init to run, and not as bad modules
run_loaded() {
	local module="$1" refused="$2" out
	out=$("$EMU" -r "$ROOT" "/tmp/$(basename "$PROBEDIR")/$module" 2>&1 || true)
	if echo "$out" | grep -Eq 'panic|CORRUPT|segmentation|fault'; then
		echo "FAIL: $module crashed the emulator"
		echo "$out"
		exit 1
	fi
	if echo "$out" | grep -q "$refused"; then
		echo "FAIL: $module was refused: $refused"
		echo "$out"
		exit 1
	fi
	echo "PASS: $module is loaded"
}
run_loaded link-mp.dis "bad module link"
run_loaded handler-ok.dis "bad exception handler"

for size in 0 1 2 4 8 16 32 64 128 256 512 1024 2048 4096; do
	cp "$ROOT/dis/sh.dis" "$PROBEDIR/truncated.dis"
	truncate -s "$size" "$PROBEDIR/truncated.dis"
	run_bad truncated.dis "truncated.dis:"
done

echo "dis_parser_bounds_test: PASS"
