#!/bin/sh
# A window's document through the window's files: a PDF shown as a
# document (read-only body, doc/ctl, Get, Render), a file open as text
# plumbed and shown, Markdown set by Render, an image
# (tests/inferno/xenith_doc_test.sh, run inside a headless Xenith).
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"
# with a plumber, as a session has: its rules send a web address to a
# port the script reads (web), so it can tell that a link clicked in
# Xenith was opened there, not plumbed away; the rest to Xenith (edit)
XENITH_INSIDE_TIMEOUT=${XENITH_INSIDE_TIMEOUT:-180} \
XENITH_INSIDE_PLUMB=/tests/xenith/plumbing xenith_inside xenith_doc /tests/inferno/xenith_doc_test.sh
