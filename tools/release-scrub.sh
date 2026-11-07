#!/bin/sh
#
# release-scrub.sh -- take every private key out of a release package's
# staging directory, and refuse the package if one is still in it.
#
# Usage:
#     tools/release-scrub.sh STAGE
#
# Every release job copies the tree's usr/ into its package, and the tree
# carries usr/inferno/keyring/default: a test key (owner "testnode"),
# which listen, styxlisten, mount, dial, cpu and rcmd take as the user's
# key when none is named. Shipped, it is the same private key on every
# install, and the repository is public. A package's keyring/ goes out
# empty; a user makes their own key (auth/createsignerkey, getauthinfo).
#
# Two steps, the second the one that matters:
#   1. every file under a usr/*/keyring/ directory is removed (the
#      directories stay, so the path a user's key belongs at exists);
#   2. the whole stage is searched for a private key in either form the
#      system uses -- an Inferno key file (a length line, then an
#      algorithm name: ed25519, elgamal, rsa, dsa) or a PEM private key --
#      and the package is refused if one is found, wherever it is. So a key
#      that arrives some other way than usr/*/keyring/ is caught too.
#
# Exit status: 0 the stage holds no private key; 1 it does (each named);
# 2 usage.

STAGE=$1
[ $# -eq 1 ] && [ -d "$STAGE" ] || { echo "usage: release-scrub.sh STAGE" >&2; exit 2; }

find "$STAGE" -type d -name keyring -path '*/usr/*/keyring' | while read -r d; do
	find "$d" -mindepth 1 -type f -print -exec rm -f {} \; | sed 's/^/release-scrub: removed /'
done

# an Inferno key file: "NNNN" then the algorithm, as keyring.c writes it.
# A function, not inline: bash 3.2 (macOS's /bin/sh) misreads a case
# pattern's ")" inside $( ).
isinfernokey() {
	head -c 64 "$1" 2>/dev/null | head -2 | tr -d '\r' | {
		read -r n && read -r alg && case $n in ''|*[!0-9]*) false ;; esac &&
		case $alg in ed25519|elgamal|rsa|dsa) true ;; *) false ;; esac; }
}

found=$(find "$STAGE" -type f -size -64k -print | while read -r f; do
	if isinfernokey "$f"; then
		echo "$f"
	elif grep -q -E -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' "$f" 2>/dev/null; then
		echo "$f"
	fi
done)

if [ -n "$found" ]; then
	echo "$found" | sed 's/^/release-scrub: a private key is in the package: /' >&2
	echo "release-scrub: refusing $STAGE" >&2
	exit 1
fi
echo "release-scrub: $STAGE holds no private key"
exit 0
