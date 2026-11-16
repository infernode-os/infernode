#!/bin/sh
# svc/auth and srv.auth start the login and key services and nothing
# else. They also started signer(8) (and svc/auth its countersigner):
# an enrolment with no client in the tree, open to anybody who connects,
# whose certificates never expire. The programs stay, started on
# purpose (signer(8), srv.signer). By the source: no emulator needed.

set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
fail=0
check() { # description, command...
	d=$1; shift
	if "$@"; then echo "ok: $d"; else echo "FAIL: $d"; fail=1; fi
}
# the lines that are commands, not comments
cmds() { grep -v '^[[:space:]]*#' "$1"; }

A=$ROOT/appl/svc/auth.sh
S=$ROOT/lib/sh/srv
check "svc/auth starts logind" sh -c "grep -v '^[[:space:]]*#' '$A' | grep -q 'inflogin.*auth/logind'"
check "svc/auth starts keysrv" sh -c "grep -v '^[[:space:]]*#' '$A' | grep -q 'infkey.*auth/keysrv'"
check "svc/auth does not start signer" sh -c "! grep -v '^[[:space:]]*#' '$A' | grep -q 'auth/signer'"
check "svc/auth does not start countersigner" sh -c "! grep -v '^[[:space:]]*#' '$A' | grep -q 'auth/countersigner'"
# srv.auth's body: from its line to the closing brace
body=$(awk '/^fn srv.auth/{p=1} p{print} p&&/^}/{exit}' "$S" | grep -v '^[[:space:]]*#')
check "srv.auth starts logind" sh -c "echo '$body' | grep -q 'auth/logind'"
check "srv.auth does not start signer" sh -c "! echo '$body' | grep -q 'signer'"
check "srv.signer starts both, for a realm that asks" sh -c "awk '/^fn srv.signer/{p=1} p{print} p&&/^}/{exit}' '$S' | grep -c 'auth/signer\|auth/countersigner' | grep -q '^2$'"
check "signer(8) says how to start them" grep -q "infsigner.*auth/signer" "$ROOT/man/8/signer"
check "the service names are still in ndb" grep -q "^tcp=infsigner" "$ROOT/lib/ndb/common"

[ $fail = 0 ] && echo "PASS: auth services" || { echo "FAIL: auth services"; exit 1; }
