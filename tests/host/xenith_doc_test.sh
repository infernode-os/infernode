#!/bin/sh
# A window's document through the window's files: a PDF shown as a
# document (read-only body, doc/ctl, Get, Render), a file open as text
# plumbed and shown, Markdown set by Render, an image
# (tests/inferno/xenith_doc_test.sh, run inside a headless Xenith).
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"
xenith_inside xenith_doc /tests/inferno/xenith_doc_test.sh
