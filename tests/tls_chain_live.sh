#!/bin/sh
# tests/tls_chain_live.sh [stock|fixed] [hosts...]
# Run tls_chain_live in a headless emulator from the main InferNode checkout,
# either as shipped (stock) or with this tree's x509.dis and lib/certs bound
# over the originals (fixed).
set -eu
wt=$(cd "$(dirname "$0")/.." && pwd)
main=${INFERNODE:-$HOME/github.com/infernode-os/infernode}
mode=${1:-fixed}; shift || true
binds=""
if [ "$mode" = fixed ]; then
	binds="bind /n/local$wt/dis/lib/crypt/x509.dis /dis/lib/crypt/x509.dis; bind /n/local$wt/dis/lib/crypt/tls.dis /dis/lib/crypt/tls.dis; bind /n/local$wt/lib/certs /lib/certs;"
fi
args=""
for a in "$@"; do args="$args '$a'"; done
cd "$main"
./emu/MacOSX/o.emu ${EMUFLAGS:--c1} -r"$main" sh -c "trfs '#U*' /n/local; ndb/cs; $binds /n/local$wt/dis/tests/tls_chain_live.dis $args; echo halt > /dev/sysctl" 2>&1 | grep -v '^mpexp:'
