#!/bin/sh
# tools/update-certs.sh: regenerate lib/certs/ (the TLS trust store) from the
# Mozilla root program, as packaged by curl (https://curl.se/docs/caextract.html).
# Writes one DER file per root, named from its Mozilla label, plus SOURCE
# (bundle date and SHA-256). Requires curl and openssl on the host.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
out=$root/lib/certs
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsS -o "$tmp/cacert.pem" https://curl.se/ca/cacert.pem
curl -fsS -o "$tmp/cacert.pem.sha256" https://curl.se/ca/cacert.pem.sha256
(cd "$tmp" && shasum -a 256 -c cacert.pem.sha256 >/dev/null)
rm -f "$out"/*.der
awk -v dir="$tmp" '
	/^[^#=-].*$/ && !incert && prev ~ /^=+$/ { label = last }
	{ if ($0 ~ /^=+$/) { label = prevline } prevline = $0 }
	/-----BEGIN CERTIFICATE-----/ { incert = 1; n++; f = sprintf("%s/%04d.pem", dir, n); print label > (f ".label") ; close(f ".label") }
	incert { print > f }
	/-----END CERTIFICATE-----/ { incert = 0; close(f) }
' "$tmp/cacert.pem"
for p in "$tmp"/[0-9]*.pem; do
	name=$(tr 'A-Z' 'a-z' < "$p.label" | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')
	[ -n "$name" ] || name=$(basename "$p" .pem)
	[ ! -e "$out/$name.der" ] || name="$name-$(basename "$p" .pem)"
	openssl x509 -in "$p" -outform DER -out "$out/$name.der"
done
{
	echo "Mozilla CA certificate store, via https://curl.se/ca/cacert.pem"
	grep -m1 '^## Certificate data from Mozilla as of' "$tmp/cacert.pem" | sed 's/^## //'
	echo "sha256 $(cut -d' ' -f1 "$tmp/cacert.pem.sha256")"
	echo "roots $(ls "$out"/*.der | wc -l | tr -d ' ')"
} > "$out/SOURCE"
cat "$out/SOURCE"
