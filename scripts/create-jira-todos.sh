#!/usr/bin/env bash
#
# create-jira-todos.sh — bulk-create Jira issues from docs/TODO-INVENTORY.md.
#
# Why this exists: the Claude Code session that catalogued the TODOs could not
# reach the Jira host (sandbox network allowlist). Run this script from a
# workstation that can reach https://nervsystems-team.atlassian.net to import
# the inventory.
#
# Required env vars:
#   JIRA_EMAIL          Atlassian account email (e.g. pdf@pdfinn.com)
#   JIRA_TOKEN          Atlassian API token (created at id.atlassian.com)
#   JIRA_PROJECT_KEY    Project key, e.g. INF (NOT the instance name)
#
# Optional env vars:
#   JIRA_BASE_URL       defaults to https://nervsystems-team.atlassian.net
#   JIRA_ISSUE_TYPE     defaults to Task
#   JIRA_EXTRA_LABEL    extra label appended to every issue, e.g. todo-import-2026-05
#   DRY_RUN             if set to 1, print payloads instead of POSTing
#   ONLY                comma-separated TODO IDs to create (e.g. TODO-007,TODO-032)
#
# Output:
#   created-issues.tsv  one row per created issue: TODO-ID<TAB>JIRA-KEY<TAB>URL
#   failed-issues.tsv   one row per failure:       TODO-ID<TAB>HTTP_CODE<TAB>error
#
# Idempotency:
#   If created-issues.tsv already lists a TODO-ID, the script skips it. Delete
#   the row (or the file) to recreate.

set -euo pipefail

: "${JIRA_EMAIL:?set JIRA_EMAIL}"
: "${JIRA_TOKEN:?set JIRA_TOKEN}"
: "${JIRA_PROJECT_KEY:?set JIRA_PROJECT_KEY (e.g. INF)}"
JIRA_BASE_URL="${JIRA_BASE_URL:-https://nervsystems-team.atlassian.net}"
JIRA_ISSUE_TYPE="${JIRA_ISSUE_TYPE:-Task}"
JIRA_EXTRA_LABEL="${JIRA_EXTRA_LABEL:-todo-import}"
DRY_RUN="${DRY_RUN:-0}"
ONLY="${ONLY:-}"

OUT_OK="created-issues.tsv"
OUT_FAIL="failed-issues.tsv"
touch "$OUT_OK" "$OUT_FAIL"

# Tab character (literal, not \t — works in awk + grep on macOS and Linux).
TAB=$'\t'

already_created() {
  grep -q "^$1${TAB}" "$OUT_OK"
}

want() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *,"$1",*) return 0 ;; esac
  return 1
}

# Build an Atlassian Document Format (ADF) description from a plain string.
# Each newline becomes a paragraph block. Single-line is the common case.
adf_description() {
  local text="$1"
  # Escape backslash and double-quote for JSON.
  text="${text//\\/\\\\}"
  text="${text//\"/\\\"}"
  cat <<EOF
{
  "type": "doc",
  "version": 1,
  "content": [
    {"type": "paragraph", "content": [{"type": "text", "text": "$text"}]}
  ]
}
EOF
}

# Build the create payload.
make_payload() {
  local summary="$1" description_text="$2" priority="$3"
  shift 3
  # Remaining args are labels.
  local labels_json="["
  local first=1
  for L in "$@" "$JIRA_EXTRA_LABEL"; do
    [ -z "$L" ] && continue
    if [ $first -eq 1 ]; then first=0; else labels_json+=","; fi
    labels_json+="\"$L\""
  done
  labels_json+="]"

  local desc_adf
  desc_adf="$(adf_description "$description_text")"

  local prio_block=""
  if [ -n "$priority" ]; then
    prio_block=",\"priority\":{\"name\":\"$priority\"}"
  fi

  cat <<EOF
{
  "fields": {
    "project": {"key": "$JIRA_PROJECT_KEY"},
    "summary": "$summary",
    "issuetype": {"name": "$JIRA_ISSUE_TYPE"},
    "labels": $labels_json,
    "description": $desc_adf
    $prio_block
  }
}
EOF
}

create_issue() {
  local todo_id="$1" summary="$2" priority="$3" description_text="$4"
  shift 4
  local labels=("$@")

  if already_created "$todo_id"; then
    echo "skip  $todo_id (already created)"
    return 0
  fi
  if ! want "$todo_id"; then
    return 0
  fi

  # Escape summary for JSON.
  local s_summary="${summary//\\/\\\\}"
  s_summary="${s_summary//\"/\\\"}"

  local payload
  payload="$(make_payload "$s_summary" "$description_text" "$priority" "${labels[@]}")"

  if [ "$DRY_RUN" = "1" ]; then
    echo "---- $todo_id ----"
    echo "$payload"
    return 0
  fi

  local resp_file
  resp_file="$(mktemp)"
  local http
  http="$(curl -sS -o "$resp_file" -w "%{http_code}" \
    -u "$JIRA_EMAIL:$JIRA_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -X POST "$JIRA_BASE_URL/rest/api/3/issue" \
    --data "$payload" || echo "000")"

  if [ "$http" = "201" ]; then
    local key
    key="$(sed -n 's/.*"key":"\([^"]*\)".*/\1/p' "$resp_file" | head -n1)"
    local url="$JIRA_BASE_URL/browse/$key"
    printf "%s${TAB}%s${TAB}%s\n" "$todo_id" "$key" "$url" >> "$OUT_OK"
    echo "ok    $todo_id -> $key"
  else
    local err
    err="$(tr -d '\n' < "$resp_file" | head -c 500)"
    printf "%s${TAB}%s${TAB}%s\n" "$todo_id" "$http" "$err" >> "$OUT_FAIL"
    echo "FAIL  $todo_id (HTTP $http)"
  fi
  rm -f "$resp_file"
}

# ============================================================================
# Issue list. Keep in sync with docs/TODO-INVENTORY.md.
# Args to create_issue:
#   TODO-ID, summary, priority (Lowest|Low|Medium|High|Highest or empty),
#   description (single-line), labels...
# ============================================================================

# --- Crypto / TLS -----------------------------------------------------------

create_issue "TODO-001" \
  "pkcs: implement MD2 in keyring module" \
  "Low" \
  "appl/lib/crypt/pkcs.b:222 and :461 — # TODO: implement md2 in keyring module. Two callsites; single keyring addition would unblock both. MD2 is legacy; needed only for old certs." \
  crypto

create_issue "TODO-002" \
  "pkcs: add gcd / getRandBetween to Keyring->IPint" \
  "Medium" \
  "appl/lib/crypt/pkcs.b:329 — # TODO: add gcd or getRandBetween in Keyring->IPint." \
  crypto

create_issue "TODO-003" \
  "ssl3: use V2Handshake.Error for SSLv2 errors" \
  "Low" \
  "appl/lib/crypt/ssl3.b:1509 — # TODO: use V2Handshake.Error for v2." \
  crypto

create_issue "TODO-004" \
  "ssl3: enforce X.509v3 KeyUsage extension" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:2381 — # TODO: to allow checking X509v3 KeyUsage extension. Security correctness." \
  crypto security

create_issue "TODO-005" \
  "ssl3: accept id == PKCS->id_rsa" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:2407 — # TODO: allow id == PKCS->id_rsa." \
  crypto

create_issue "TODO-006" \
  "ssl3: factor X.509 cert handling into a separate module" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:2460 — # TODO: use another module to do x509 certs, lookup and matching rules. Refactor." \
  crypto refactor

create_issue "TODO-007" \
  "ssl3: validate client cert type when CLIENT_AUTH set" \
  "High" \
  "appl/lib/crypt/ssl3.b:2820 — # TODO: need check type of client cert if(!ctx.status & CLIENT_AUTH). Security." \
  crypto security

create_issue "TODO-008" \
  "ssl3: gate cipher selection on supported_cipher_kinds (two sites)" \
  "High" \
  "appl/lib/crypt/ssl3.b:4562 and :4652 — # TODO: should in supported cipher_kinds. Security." \
  crypto security

create_issue "TODO-009" \
  "ssl3: decode v2hs.certificate as a list of certificates" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:4689 — # TODO: decode v2hs.certificate as list of certificate." \
  crypto

create_issue "TODO-010" \
  "ssl3: extend CipherSpec ADT to carry richer key info" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:4720 and :4808 — # TODO: change CipherSpec adt for more key info; downstream lines blocked on this ADT change." \
  crypto refactor

create_issue "TODO-011" \
  "ssl3: resolve three empty TODO markers" \
  "Low" \
  "appl/lib/crypt/ssl3.b:4786, :4836, :4884 — bare # TODO: with no further detail. Investigate intent (likely cipher/key setup nearby) and either implement or delete." \
  crypto

create_issue "TODO-012" \
  "ssl3: validate key block size when IV is present" \
  "Medium" \
  "appl/lib/crypt/ssl3.b:4932 — # TODO: check the size of key block if IV exists." \
  crypto

create_issue "TODO-013" \
  "ssl3: validate SSL2 challenge / connection_id lengths" \
  "Low" \
  "appl/lib/crypt/ssl3.b:4942 and :4943 — # TODO: if challenge length != 16 ? / # TODO: if connection_id length != 16 ?" \
  crypto

create_issue "TODO-014" \
  "sslsession: evict expired sessions" \
  "Medium" \
  "appl/lib/crypt/sslsession.b:104 — # TODO: remove expired session." \
  crypto

create_issue "TODO-015" \
  "x509: derive AlgIdentifier from public key + hash" \
  "Medium" \
  "appl/lib/crypt/x509.b:395 — # TODO: add AlgIdentifier based on public key and hash." \
  crypto

create_issue "TODO-016" \
  "x509: implement signing/verifying tobe_signed hash" \
  "High" \
  "appl/lib/crypt/x509.b:398 and :469 — # TODO: hash s.tobe_signed for signing / for verifying. Cert sign/verify path is incomplete." \
  crypto security

create_issue "TODO-017" \
  "x509: determine ASN.1 object type from OID" \
  "Medium" \
  "appl/lib/crypt/x509.b:1068 — # TODO: determine the object type based on oid." \
  crypto

create_issue "TODO-018" \
  "x509: convert times to coordinate (UTC) time" \
  "Medium" \
  "appl/lib/crypt/x509.b:1412 — # TODO: convert to coordinate time." \
  crypto

create_issue "TODO-019" \
  "x509: handle differing string encodings (T61String vs IA5String)" \
  "Low" \
  "appl/lib/crypt/x509.b:1749 — # TODO: need to match different encoding (T61String vs. IA5String)." \
  crypto

create_issue "TODO-020" \
  "x509: use IPint instead of int when parsing large integers" \
  "Medium" \
  "appl/lib/crypt/x509.b:3491 — # TODO: should be IPint." \
  crypto

create_issue "TODO-021" \
  "pkcs.m: move AlgIdentifier ADT to ASN1 module" \
  "Low" \
  "module/pkcs.m:177 — # TODO: move this to ASN1. Refactor." \
  crypto refactor

create_issue "TODO-022" \
  "asn1: recurse and concat results in unhandled SET path" \
  "Medium" \
  "appl/lib/asn1.b:200 — # TODO: recurse and concat results." \
  crypto

create_issue "TODO-023" \
  "asn1: parse the value internally instead of returning bytes" \
  "Low" \
  "appl/lib/asn1.b:273 — # TODO: parse this internally." \
  crypto

# --- Charon -----------------------------------------------------------------

create_issue "TODO-024" \
  "charon/build: handle other element kinds" \
  "Low" \
  "appl/charon/build.b:1571 — # TODO: other kinds." \
  charon

create_issue "TODO-025" \
  "charon: choose a different protocol for inter-process control" \
  "Low" \
  "appl/charon/charon.b:2107 — # TODO: should really use a different protocol." \
  charon

create_issue "TODO-026" \
  "charon/img: un-interlace PNG in place" \
  "Low" \
  "appl/charon/img.b:723 — # (TODO: Could un-interlace in place. Memory optimisation." \
  charon

create_issue "TODO-027" \
  "charon/jscript: handle document text from evalscript" \
  "Medium" \
  "appl/charon/jscript.b:1031 — # TODO - handle document text from evalscript." \
  charon

create_issue "TODO-028" \
  "charon/jscript: harden two unsafe call sites" \
  "Medium" \
  "appl/charon/jscript.b:1234 and :1547 — # TODO: be more defensive (twice). Potential crash sites." \
  charon

create_issue "TODO-029" \
  "charon/layout: read font from \$font env or config file" \
  "Low" \
  "appl/charon/layout.b:263 — #TODO should read from env \$font or config." \
  charon

create_issue "TODO-030" \
  "charon/layout: skip layout pass when y/height unchanged (two sites)" \
  "Low" \
  "appl/charon/layout.b:980 and :1656 — # TODO: only do following / only change if y and/or height changed. Perf." \
  charon performance

# --- Lucifer / Lucipres -----------------------------------------------------

create_issue "TODO-031" \
  "lucifer: explicitly destroy old window in Screen.newwindow" \
  "Medium" \
  "appl/cmd/lucifer.b:893 — # TODO: Screen.newwindow() returns a fresh window; old window should be explicitly destroyed." \
  lucifer

create_issue "TODO-032" \
  "lucifer: reclaim app slots when an app crashes (watchdog)" \
  "High" \
  "appl/cmd/lucifer.b:2257 (related :1956) — # TODO: when an app crashes (no orderly exit), its client may linger in appslots. docs/LUCIA-EVALUATION.md recommends a watchdog that periodically checks client.ctl and refuses spawns when nappslots >= MAXAPPSLOTS." \
  lucifer

create_issue "TODO-033" \
  "lucipres: refactor presentation rendering into its own wmclient app" \
  "Medium" \
  "appl/cmd/lucipres.b:11 — full design in docs/TODO-LUCIPRES-ARCHITECTURE.md. Presentation rendering is drawn into lucipres's image while app tabs are wmclient windows, causing z-order races on tab switch. Non-trivial refactor: render registry, all renderers, async pipeline, scroll/zoom/pan state, PDF nav, agent integration." \
  lucipres refactor architecture

# --- Mail -------------------------------------------------------------------

create_issue "TODO-034" \
  "Mailpop3: emit Plan 9 mail header so Mail can read; quote From" \
  "Medium" \
  "appl/acme/acme/mail/Mailpop3.b:991 (and forked appl/xenith/xenith/mail/Mailpop3.b:991 — fix in both, or unify the forks). # TODO: create the plan9 header so Mail can read it. and quote From." \
  acme mail

# --- Shell / utilities ------------------------------------------------------

create_issue "TODO-035" \
  "sh: clarify intentional '* => raise e' and document" \
  "Low" \
  "appl/cmd/sh/sh.b:957 — # TODO the manual says that leaving this out is intentional. Investigate whether the catch-all is required or whether man-page rendering depends on its absence; document the conclusion." \
  sh

create_issue "TODO-036" \
  "wikifs: rewrite wlink wiki-link parser ('this is all wrong')" \
  "Medium" \
  "appl/cmd/wikifs/wiki.b:439 — # TODO this is all wrong. Comment flags the entire [link] parsing block in wlink() as broken; likely mishandles nested or malformed brackets." \
  wikifs

create_issue "TODO-037" \
  "dict/pgw: add foreign-consonant transcriptions" \
  "Low" \
  "appl/cmd/dict/pgw.b:1050 — #  TODO: find transcriptions of foreign consonents, S, , nasals." \
  dict

# --- HTTP service -----------------------------------------------------------

create_issue "TODO-038" \
  "httpd: implement compile-hint generation (currently skipped)" \
  "Low" \
  "appl/svc/httpd/httpd.b:621 — # TODO Skip doing hints for now." \
  httpd

# --- Build / tooling --------------------------------------------------------

create_issue "TODO-039" \
  "Rebuild hosted limbo (dis/limbo.dis) for ARM64 correctness" \
  "High" \
  "build-macos-sdl3.sh:5-17 — !!! CRITICAL TODO !!!. emu-hosted Limbo compiler emits invalid bytecode (BADOP at runtime) on ARM64. Build script tells users to use the native compiler as a workaround. Real fix is to repair the hosted compiler." \
  build limbo

create_issue "TODO-040" \
  "emu/Nt/devfs: try '/' in place of '\\\\' in path names" \
  "Low" \
  "emu/Nt/devfs.c:12 — /* TODO: try using / in place of backslash in path names */. Windows host only." \
  emu windows

create_issue "TODO-041" \
  "libtk/grids: investigate 'XXX TODO' placeholder" \
  "Low" \
  "libtk/grids.c:6 — * XXX TODO. Bare placeholder; investigate intent." \
  tk

# --- Tests ------------------------------------------------------------------

create_issue "TODO-042" \
  "fix bufio_test.SopenGett (gett returns fields with delimiter attached)" \
  "Medium" \
  "tests/bufio_test.b:10 — # TODO: SopenGett fails — gett returns fields with delimiter still attached." \
  tests bufio

create_issue "TODO-043" \
  "fix cowfs_test (file2chan server does not shut down, runner hangs)" \
  "Medium" \
  "tests/cowfs_test.b:12 — # TODO: This test hangs the runner — the cowfs file2chan server does not shut down." \
  tests cowfs

# --- Formal-verification race conditions ------------------------------------

create_issue "TODO-044" \
  "kchdir: use-after-free on pg->dot swap" \
  "High" \
  "emu/port/sysfile.c:142-157 — kchdir performs cclose(pg->dot) then pg->dot = c with no lock; concurrent namec() can read freed channel pointer. Fix: hold pg->ns write lock around the close-and-reassign. SPIN counterexample in formal-verification/spin/namespace_races.pml." \
  emu concurrency race formal-verification

create_issue "TODO-045" \
  "Sys_pctl FORKNS: pgrp pointer swap without lock" \
  "Medium" \
  "emu/port/inferno.c:869-876 — after release(), other emu threads can see stale up->env->pgrp; closepgrp(opg) may free a still-cached pointer. Fix: lock or atomic CAS around the pgrp pointer swap, or refcount the pgrp pointer so closepgrp defers until readers release." \
  emu concurrency race formal-verification

create_issue "TODO-046" \
  "namec: unsynchronised reads of pg->slash / pg->dot" \
  "Medium" \
  "emu/port/chan.c:1020-1058 — namec reads pg->slash or pg->dot without holding pg->ns; concurrent kchdir or Sys_pctl FORKNS could free or replace the pointer between read and incref. Fix: read-lock pg->ns around read+incref, or use atomic pointer ops." \
  emu concurrency race formal-verification

# --- Xenith roadmap ---------------------------------------------------------

create_issue "TODO-047" \
  "Xenith: agent hooks (pre/post/error filesystem hooks)" \
  "Medium" \
  "appl/xenith/IDEAS.md:331 — expose /lib/agent/hooks/{pre_command,post_command,on_error} so users can audit, log, rate-limit, auto-commit, or validate agent actions. Env vars: \$COMMAND, \$RESULT, \$ERROR." \
  xenith veltro feature

create_issue "TODO-048" \
  "Xenith: progressive PNG loading verification test" \
  "Medium" \
  "appl/xenith/IDEAS.md:387 — progressive decode infrastructure exists but is imperceptible on fast storage. Verification test: insert 500ms sleep in loadpngsubsampleprogressive() and feed a >16MP gradient PNG; expect top-to-bottom incremental fill, no UI freeze, ~10 progress messages." \
  xenith test

create_issue "TODO-049" \
  "Implement ARM64 JIT compiler for Dis VM" \
  "High" \
  "appl/xenith/IDEAS.md:447 (also libinterp/comp-arm64.c and libinterp/comp-amd64.c — both stubs). Estimated 10-100x speedup for CPU-bound Limbo. ~35-40 KB of C. ARM 32-bit JIT (libinterp/comp-arm.c) is the closest reference; libinterp/comp-386.c is the most complete." \
  libinterp jit performance epic

# ----------------------------------------------------------------------------

echo
echo "Done."
echo "  Created: $(wc -l < "$OUT_OK" | tr -d ' ')"
echo "  Failed:  $(wc -l < "$OUT_FAIL" | tr -d ' ')"
echo "Logs: $OUT_OK, $OUT_FAIL"
