#!/bin/sh
# escape-lab.sh — outer-lab evidence launcher for the Veltro Escape Room.
#
# The escape-room protocol keeps two trees of evidence. The inner one belongs
# to grind.py inside the target VM and is private by construction. The outer
# one belongs to the lab around it — packet capture, guest console, the
# command log, the disposable overlay, the campaign manifest — and is written
# by QEMU and by the operator's shell, neither of which knows anything about
# the protocol.
#
# In RUN-20260824T222058Z-CAMPAIGN the outer directory was correctly 0700 but
# QEMU created target-net.pcap and target-console.log as 0644, because the
# launch shell had the default umask. They were corrected to 0600 while
# capture was still running; for the window before that, the packet capture of
# an adversarial containment trial was readable by every account on the lab
# host. This script exists so that window cannot open (INFR-412).
#
# Usage:
#   escape-lab.sh init  <rundir>              create the run tree, private
#   escape-lab.sh check <rundir>              preflight: abort if not private
#   escape-lab.sh seal  <rundir>              re-assert modes, record them
#   escape-lab.sh run   <rundir> <cmd> [arg…] init + check, then run under 077
#
# `run` is the one to use for QEMU, packet capture, and the campaign itself:
# it sets umask 077 for the child, so files the child creates that this script
# never hears about are private too, and it refuses to start when anything
# already in the tree is group- or world-accessible.
#
# The evidence paths are exported for the child to use:
#   ESCAPE_LAB_RUNDIR ESCAPE_LAB_PCAP ESCAPE_LAB_CONSOLE
#   ESCAPE_LAB_CMDLOG ESCAPE_LAB_OVERLAY ESCAPE_LAB_MANIFEST
#
# Public artifacts are NOT derived here. Everything this script touches is raw
# evidence; a shareable copy is produced separately, after redaction and after
# a canary scan proves the redaction held — see docs/VELTRO-ESCAPE-ROOM.md.

set -eu

# Private by construction, not by the operator's login shell. Set before the
# first mkdir so that even a path this script does not chmod is created 0700.
umask 077

PCAP_NAME="${ESCAPE_LAB_PCAP_NAME:-target-net.pcap}"
CONSOLE_NAME="${ESCAPE_LAB_CONSOLE_NAME:-target-console.log}"
CMDLOG_NAME="${ESCAPE_LAB_CMDLOG_NAME:-target-command.log}"
OVERLAY_NAME="${ESCAPE_LAB_OVERLAY_NAME:-target-overlay.qcow2}"
MANIFEST_NAME="${ESCAPE_LAB_MANIFEST_NAME:-manifest.json}"

# Pre-created so the very first byte QEMU writes lands in a 0600 file. The
# overlay is not among them: qemu-img creates it itself, so it is asserted
# after the fact instead (check/seal cover it).
PRECREATED="$PCAP_NAME $CONSOLE_NAME $CMDLOG_NAME $MANIFEST_NAME"

die() { echo "escape-lab: $*" >&2; exit 1; }

usage() {
	sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-2}"
}

# `stat` is not portable between GNU and BSD; ask both.
modeof() {
	if stat -c '%a' "$1" 2>/dev/null; then
		:
	else
		stat -f '%Lp' "$1"
	fi
}

# Anything carrying a group or other permission bit, one path per line.
# POSIX find's -perm -<octal> means "at least these bits", so this is one
# expression per bit rather than a mask test, and it works on GNU and BSD.
leaky_paths() {
	find "$1" \( -perm -0001 -o -perm -0002 -o -perm -0004 \
	          -o -perm -0010 -o -perm -0020 -o -perm -0040 \) -print
}

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# A leading zero makes the arithmetic constant octal, so this is a plain
# "any group or other bit set" test in POSIX sh.
leaky_mode() { [ $(( 0$1 & 077 )) -ne 0 ]; }

# Paths init had to repair rather than create. Repairing an existing evidence
# file is not reassuring: it is the campaign's own failure — pcap and console
# were corrected to 0600 only after capture had started — so `run` treats a
# non-empty list as a reason to stop rather than as housekeeping.
REPAIRED=""

cmd_init() {
	rundir="$1"
	REPAIRED=""
	if [ -d "$rundir" ]; then
		mode="$(modeof "$rundir")"
		if leaky_mode "$mode"; then
			REPAIRED="$REPAIRED .($mode)"
			chmod 0700 "$rundir"
		fi
	else
		mkdir -p "$rundir"
		chmod 0700 "$rundir"
	fi
	# The overlay is created by qemu-img, so it is asserted when present
	# rather than pre-created; everything else is pre-created empty so the
	# very first byte QEMU writes already lands in a 0600 file.
	for name in $PRECREATED $OVERLAY_NAME; do
		path="$rundir/$name"
		if [ -e "$path" ]; then
			mode="$(modeof "$path")"
			if leaky_mode "$mode"; then
				REPAIRED="$REPAIRED $name($mode)"
				chmod 0600 "$path"
			fi
		elif [ "$name" != "$OVERLAY_NAME" ]; then
			: > "$path"
			chmod 0600 "$path"
		fi
	done
	echo "escape-lab: $rundir ready (0700 directory, 0600 evidence files)"
	if [ -n "$REPAIRED" ]; then
		echo "escape-lab: repaired group/world-accessible evidence:$REPAIRED" >&2
	fi
}

cmd_check() {
	rundir="$1"
	[ -d "$rundir" ] || die "$rundir does not exist — run 'escape-lab.sh init' first"
	mode="$(modeof "$rundir")"
	[ "$mode" = "700" ] || die "$rundir is mode $mode, expected 700"
	missing=""
	for name in $PRECREATED; do
		[ -e "$rundir/$name" ] || missing="$missing $name"
	done
	[ -z "$missing" ] || die "evidence missing:$missing — run 'escape-lab.sh init'"
	leaky="$(leaky_paths "$rundir")"
	if [ -n "$leaky" ]; then
		echo "escape-lab: group/world-accessible evidence:" >&2
		echo "$leaky" | while read -r path; do
			echo "  $path: $(modeof "$path")" >&2
		done
		die "refusing to proceed — private evidence is readable by other accounts"
	fi
	echo "escape-lab: $rundir is private (0700 directories, 0600 files)"
}

cmd_seal() {
	rundir="$1"
	[ -d "$rundir" ] || die "$rundir does not exist"
	find "$rundir" -type d -exec chmod 0700 {} +
	find "$rundir" -type f -exec chmod 0600 {} +
	cmd_check "$rundir"
	# Recorded, not just asserted: a campaign report should be able to show
	# the mode every evidence file was sealed at without trusting this run.
	modes="$rundir/evidence-modes.txt"
	{
		echo "# escape-lab seal $(stamp)"
		find "$rundir" ! -name evidence-modes.txt | sort | while read -r path; do
			echo "$(modeof "$path") $path"
		done
	} > "$modes"
	chmod 0600 "$modes"
	echo "escape-lab: sealed, modes recorded in $modes"
}

cmd_run() {
	rundir="$1"
	shift
	[ $# -gt 0 ] || usage
	cmd_init "$rundir"
	if [ -n "$REPAIRED" ]; then
		die "evidence was already readable by other accounts:$REPAIRED — \
investigate the exposure before running another trial"
	fi
	cmd_check "$rundir"

	ESCAPE_LAB_RUNDIR="$rundir"
	ESCAPE_LAB_PCAP="$rundir/$PCAP_NAME"
	ESCAPE_LAB_CONSOLE="$rundir/$CONSOLE_NAME"
	ESCAPE_LAB_CMDLOG="$rundir/$CMDLOG_NAME"
	ESCAPE_LAB_OVERLAY="$rundir/$OVERLAY_NAME"
	ESCAPE_LAB_MANIFEST="$rundir/$MANIFEST_NAME"
	export ESCAPE_LAB_RUNDIR ESCAPE_LAB_PCAP ESCAPE_LAB_CONSOLE \
	       ESCAPE_LAB_CMDLOG ESCAPE_LAB_OVERLAY ESCAPE_LAB_MANIFEST

	echo "$(stamp) $*" >> "$ESCAPE_LAB_CMDLOG"
	# umask is already 077 and is inherited, so anything the child creates
	# without asking — QEMU's own temporary files included — is private.
	exec "$@"
}

case "${1:-}" in
	-h|--help|help|"") usage 0 ;;
esac
[ $# -ge 2 ] || usage
action="$1"
shift
case "$action" in
	init)  cmd_init "$1" ;;
	check) cmd_check "$1" ;;
	seal)  cmd_seal "$1" ;;
	run)   cmd_run "$@" ;;
	*) die "unknown action '$action'" ;;
esac
