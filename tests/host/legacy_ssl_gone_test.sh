#!/bin/bash
#
# tests/host/legacy_ssl_gone_test.sh
#
# The SSL 3.0 client (appl/lib/crypt/ssl3.b, with its session cache
# sslsession.b) is not in the tree, and nothing in it speaks SSL 3.0.
#
# It authenticated nothing an active attacker could not supply: a
# ServerHello with an empty session id finished a handshake with no
# certificate and no key, a server's key exchange was not checked against
# its certificate, a suite never offered was taken, and no name was
# compared with the certificate.  Its two users, pop3(2) and the webget
# service's https, use tls(2).  This is a pin on the source: a module of
# that name, a load of one, or an include of its interface fails it.
#
#   - no ssl3 or sslsession source, interface or Dis file
#   - no Limbo source or interface names the modules, their interfaces
#     or their Dis files; no mkfile or prototype lists them
#   - pop3(2) and webget's http make their TLS through tls(2)
#     (mailconn(2), webclient(2)), not a client of their own
#
# No emulator needed.  Run from project root:
#   ./tests/host/legacy_ssl_gone_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

PASSED=0; FAILED=0
pass()  { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail()  { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# Under dis/ any file of theirs counts: it is what a load would find.
# Beside the sources a .dis or .sbl is what an earlier build left in a
# tree that has since been pulled (mk no longer knows to remove it); it
# is loaded by nothing and is not the tree's.
found=$(find appl module dis lib os tests \( -iname 'ssl3.*' -o -iname 'sslsession.*' \) 2>/dev/null |
	grep -v '^tests/host/legacy_ssl_gone_test.sh$' |
	grep -Ev '^(appl|module|lib|os|tests)/.*\.(dis|sbl)$')
if [[ -z "$found" ]]; then
    pass "no ssl3 or sslsession source, interface or Dis file"
else
    fail "files of the SSL 3.0 client: $found"
fi

# a load, an include, a module's name or its path, in Limbo source
uses=$(grep -rnI --include='*.b' --include='*.m' \
    -e 'include[ 	]*"ssl3\.m"' -e 'include[ 	]*"sslsession\.m"' \
    -e 'load[ 	]*SSL3\b' -e 'load[ 	]*SSLsession\b' \
    -e 'SSL3->' -e 'SSLsession->' -e 'ssl3\.dis' -e 'sslsession\.dis' \
    appl module os tests 2>/dev/null)
if [[ -z "$uses" ]]; then
    pass "no Limbo source includes, loads or names the modules"
else
    fail "uses of the SSL 3.0 client: $uses"
fi

lists=$(grep -rnI -e 'ssl3\.' -e 'sslsession\.' $(find appl tests -name mkfile) lib/proto 2>/dev/null)
if [[ -z "$lists" ]]; then
    pass "no mkfile or prototype lists them"
else
    fail "still listed: $lists"
fi

if grep -q 'include "mailconn.m"' appl/lib/pop3.b && grep -q 'tls->client' appl/lib/mailconn.b &&
   ! grep -q 'Context\.new\|sslx' appl/lib/pop3.b; then
    pass "pop3(2)'s TLS is tls(2)'s client, through mailconn(2)"
else
    fail "pop3.b does not make its TLS through mailconn(2)"
fi
if grep -q 'webclient->tlsclient' appl/svc/webget/http.b && ! grep -q 'Context\.new\|sslx' appl/svc/webget/http.b; then
    pass "webget's https is tls(2)'s client, through webclient(2)"
else
    fail "webget's http.b does not make its TLS through webclient(2)"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
