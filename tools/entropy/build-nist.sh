#!/bin/sh
#
# tools/entropy/build-nist.sh - build NIST's SP 800-90B entropy
# assessment tools (usnistgov/SP800-90B_EntropyAssessment) at the commit
# this tree's results were made with, into $ROOT/tmp/nist. Prints the
# directory holding ea_iid, ea_non_iid and ea_restart.
#
# Needs git, make, a C++ compiler and the tool's libraries: on Debian
# or Ubuntu, libbz2-dev libdivsufsort-dev libjsoncpp-dev libgmp-dev
# libmpfr-dev libssl-dev; on macOS, brew install bzip2 libdivsufsort
# jsoncpp gmp mpfr openssl.
#
set -e
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
COMMIT=87c104d0ed4cbc96103e7b8b38d6f2c7e0a6b289	# 2026-05-26
DIR="$ROOT/tmp/nist"
if [ -x "$DIR/cpp/ea_non_iid" ] && [ "$(git -C "$DIR" rev-parse HEAD 2>/dev/null)" = "$COMMIT" ]; then
	echo "$DIR/cpp"
	exit 0
fi
rm -rf "$DIR"
mkdir -p "$ROOT/tmp"
git clone -q https://github.com/usnistgov/SP800-90B_EntropyAssessment.git "$DIR" >&2
git -C "$DIR" checkout -q "$COMMIT"
make -C "$DIR/cpp" -j4 non_iid iid restart >&2
echo "$DIR/cpp"
