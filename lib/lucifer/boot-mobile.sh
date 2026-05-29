# Mobile boot wrapper — Phase 2b.2 (INFR-113).
#
# Invoked as: sh -l /lib/lucifer/boot-mobile.sh
# (from android-app/.../InfernodeSDLActivity.kt getArguments())
#
# Does mobile-specific setup that should NOT run on desktop, then
# hands off to the regular boot.sh. Keeping mobile concerns in a
# separate file means desktop boot is unchanged byte-for-byte —
# no risk of regressing desktop boot timings or behaviour from
# Android-only patches.
#
# Why not gate the mobile setup inside boot.sh on $emuhost? Because
# changing emu/Android/os.c's hosttype to "Android" broke critical
# profile blocks gated on `$emuhost MacOSX Linux Nt` (trfs /n/local,
# $infhome, secstore overlay binds). hosttype stays "Linux"; the
# Android-specific behaviour selector is *which boot script* the
# Activity invokes.

# KLUDGE-MOBILE-ACCORDION-INFR-119 — mobile-mode signal for
# wm/lucifer. Lucifer reads /env/infmobile in init() and switches
# to the accordion layout (zonerects / drawchrome / mouseproc) when
# this is "1". Remove this line + every other site tagged INFR-119
# when the proper split-zones + pager refactor lands.
infmobile = 1

# ── Telephony / SMS (devphone) ──────────────────────────────
# #f is the radio device — only registered in mobile emu builds
# (emu/iOS, emu/Android) and only bound here, where we know we have
# a radio. Desktops don't get this; if they want telephony they
# mount a phone's exported /phone over 9P (see lib/sh/profile +
# docs/HELLAPHONE.md).
mkdir /phone >[2] /dev/null
bind -a '#f' /phone >[2] /dev/null

# Bigger fonts for phone screens.
#
# Lucifer and most UI elements (wm/shell, wm/editor, acme, xenith,
# charon, lucipres, wm/logon) open fonts from /fonts/combined/. On a
# ~388 dpi phone screen the default 10–14 pt sizes are microscopic
# and tap targets sized to them are unhittable. Bind larger glyphs
# over the small-tier paths at the file level so every consumer
# picks up the bigger sizes without code changes.
#
# Two families:
#   unicode.14.font          — proportional sans-mono, used by
#                              wm/shell, wm/editor, acme, xenith,
#                              charon, lucifer, lucipres (anything
#                              with code/terminal alignment). On
#                              mobile we sacrifice column alignment
#                              for legibility — bind sans.24 over
#                              it. Revisit when we generate real
#                              larger mono glyphs from DejaVuSansMono.
#   unicode.sans.* family    — proportional sans, used by wm/logon
#                              body text, smallfont, Lucifer chrome,
#                              Veltro UI. Responds cleanly to scale.
#
# Floor is sans.18 (small UI labels). 14 and 18 jump to 24. Bold
# tier scales the same.
# INFR-115 mobile font ladder: real 32pt subfonts from
# tools/gen-mobile-fonts.sh (DejaVu*.32.* under fonts/dejavu/ + the
# matching unicode.sans.48.font / unicode.sans.bold.48.font /
# unicode.32.font combined manifests under fonts/combined/).
#
# Small UI labels (10/12) → sans.24. Body and anything 14/18/24
# → sans.32. Bold tier scales the same. The unicode.14.font slot —
# used by mono-context apps (wm/shell, wm/editor, acme, xenith,
# charon, lucifer, lucipres) — binds to the proportional-mono
# unicode.32.font so terminals and code editors get crisp mono
# glyphs at the new size instead of the proportional fallback the
# earlier (sans.24 over unicode.14.font) stopgap produced.
bind /fonts/combined/unicode.sans.24.font /fonts/combined/unicode.sans.10.font >[2] /dev/null
bind /fonts/combined/unicode.sans.24.font /fonts/combined/unicode.sans.12.font >[2] /dev/null
bind /fonts/combined/unicode.sans.48.font /fonts/combined/unicode.sans.14.font >[2] /dev/null
bind /fonts/combined/unicode.sans.48.font /fonts/combined/unicode.sans.18.font >[2] /dev/null
bind /fonts/combined/unicode.sans.48.font /fonts/combined/unicode.sans.24.font >[2] /dev/null
bind /fonts/combined/unicode.sans.bold.24.font /fonts/combined/unicode.sans.bold.12.font >[2] /dev/null
bind /fonts/combined/unicode.sans.bold.48.font /fonts/combined/unicode.sans.bold.14.font >[2] /dev/null
bind /fonts/combined/unicode.sans.bold.48.font /fonts/combined/unicode.sans.bold.18.font >[2] /dev/null
bind /fonts/combined/unicode.sans.bold.48.font /fonts/combined/unicode.sans.bold.24.font >[2] /dev/null
bind /fonts/combined/unicode.48.font /fonts/combined/unicode.14.font >[2] /dev/null

# Dev-mode toggle: when the Activity passes --no-logon as the last
# argv, skip wm/logon in boot.sh below. Temporary convenience for
# mobile UI iteration — every test rebuild would otherwise demand a
# password before the screen we're trying to inspect renders.
# secstore stays locked and factotum starts empty in this mode.
# Flip the default in InfernodeSDLActivity when LLM/keyring work
# needs auth.
if {~ $* --no-logon} {
	skiplogon = 1
	echo 'boot-mobile: dev mode (--no-logon)'
}

# Hand off to the canonical boot sequence. `run` is Inferno sh's
# source-include builtin (sh-std(1)); `. file` is NOT the same as
# in POSIX sh — there `.` is a command name and resolves to ./..dis,
# which silently failed and left the user staring at a blank screen
# for 30+ seconds while boot stalled.
run /lib/lucifer/boot.sh
