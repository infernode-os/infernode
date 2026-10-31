#!/bin/sh
# Regenerate the test PKI (see README). Requires openssl. Keys are
# discarded: the fixtures only need certificates.
set -eu
cd "$(dirname "$0")"
D=8400	# days; keeps notAfter a UTCTime (before 2050) for decades of runs
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ec() { openssl ecparam -name "${2:-prime256v1}" -genkey -noout -out "$tmp/$1.key"; }
root() {	# name subject hash [curve|rsa]
	if [ "${4:-}" = rsa ]; then openssl genrsa -out "$tmp/$1.key" 2048 2>/dev/null; else ec "$1" "${4:-prime256v1}"; fi
	openssl req -x509 -new -key "$tmp/$1.key" -subj "/CN=$2" -days $D -"$3" \
		-addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$tmp/$1.pem"
}
issue() {	# name subject issuer profile hash [rsa]
	if [ "${6:-}" = rsa ]; then openssl genrsa -out "$tmp/$1.key" 2048 2>/dev/null; else ec "$1"; fi
	openssl req -new -key "$tmp/$1.key" -subj "/CN=$2" -out "$tmp/$1.csr"
	openssl x509 -req -in "$tmp/$1.csr" -CA "$tmp/$3.pem" -CAkey "$tmp/$3.key" -CAcreateserial \
		-days $D -"$5" -extfile ext.cnf -extensions "$4" -out "$tmp/$1.pem" 2>/dev/null
}
root  root   "InferNode Test Root" sha256
issue inter  "InferNode Test Intermediate" root ca sha256
issue leaf   "test.infernode.invalid" inter leaf sha256
issue notca  "InferNode Test NotCA" root notca sha256
issue leaf-notca "test.infernode.invalid" notca leaf sha256
issue nosign "InferNode Test NoCertSign" root nosign sha256
issue leaf-nosign "test.infernode.invalid" nosign leaf sha256
issue inter0 "InferNode Test PathLen0" root ca0 sha256
issue inter1 "InferNode Test Under PathLen0" inter0 ca sha256
issue leaf-pathlen "test.infernode.invalid" inter1 leaf sha256
ec self
openssl req -x509 -new -key "$tmp/self.key" -subj "/CN=test.infernode.invalid" -days $D -sha256 \
	-addext "subjectAltName=DNS:test.infernode.invalid" -out "$tmp/self.pem"
root  rroot  "InferNode Test RSA Root" sha384 rsa
issue rleaf  "test.infernode.invalid" rroot leaf sha512 rsa
root  eroot  "InferNode Test P384 Root" sha384 secp384r1
issue eleaf  "test.infernode.invalid" eroot leaf sha256
rm -f ./*.der anchors/*.der
mkdir -p anchors
for p in "$tmp"/*.pem; do n=$(basename "$p" .pem); openssl x509 -in "$p" -outform DER -out "$n.der"; done
cp root.der rroot.der eroot.der anchors/
