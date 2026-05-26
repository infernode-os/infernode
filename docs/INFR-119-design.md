# INFR-119 — Split Lucifer mobile zones into wm windows + generic pager

**Status:** design / proposal — pre-implementation. Replaces the
`KLUDGE-MOBILE-ACCORDION-INFR-119` annotations across `appl/cmd/lucifer.b`,
`appl/cmd/luciconv.b`, `appl/cmd/lucipres.b`, `appl/cmd/lucictx.b`.

**Author:** initial draft, May 2026. Subject to revision before any
code lands.

## Why the accordion exists

Mobile Lucifer (`infmobile=1`) shows Chat, Workspace, and Context
stacked as three title-bar accordions instead of the desktop's
three-column layout. The three zones live in the same window — they
share one bodyr — and a z-order toggle (`topexpandedzone`) raises the
selected zone's sub-image to the front. The three zone modules
(`luciconv`, `lucipres`, `lucictx`) each draw into their own
sub-image and run their own input loop, but they:

  * receive their sub-image, font, and channels from `lucifer.b`,
  * have no idea they're inside a "zone" — they think they own
    the whole window they were handed,
  * depend on `lucifer.b` to repaint title bars, route taps, and
    keep their sub-images sized correctly.

That worked for shipping mobile fast, but it has cost two rounds of
debugging already (PR #125's name-leak / sentinel / blocking-send
round, then PR #139's `appreaper` + `preswmloop` + `1×1 segv` round)
because the zone modules and `lucifer.b` are tightly coupled through
shared state and ad-hoc resize signalling.

## What this proposal replaces it with

Two things, both reusable by anything that wants to be a top-level wm
client on a phone:

### 1. The three zone modules become normal `wmclient` apps

Each of `luciconv`, `lucipres`, `lucictx` becomes a self-contained
wm app:

  * Takes a `ref Draw->Context` and `args` exactly like every other
    `/dis/wm/*` module (`wm/acme`, `wm/charon`).
  * Calls `wmclient->window(ctxt, "Chat" | "Workspace" | "Context",
    Wmclient->Plain)` to ask the window manager for its window —
    same call `wm/acme` uses.
  * Owns its own mainloop and gets resize / mouse / keyboard events
    through standard `wm` channels (`wmctl`, `wmcursor`, etc.).
  * Knows nothing about the other two zones, about the Lucifer
    header, or about "mobile" vs "desktop". It just draws to whatever
    rectangle `wm` gives it.

The net effect: each zone is just another wm window. Lucifer doesn't
have to layout-route-redraw it.

### 2. A generic `/dis/wm/pager.dis`

A new wm app — *not* mobile-specific in API, just useful on phones —
that:

  * Hosts a set of child wm windows in a single visible-at-a-time
    stack.
  * Renders a row of tappable title bars (the "tabs") at the top.
  * Lets you swipe horizontally to switch (uses
    `mousetrack(8/16/32/64)` from INFR-121's swipe synth).
  * Forwards mouse / keyboard to the active child only; other
    children stay live (so e.g. an inbound LLM response keeps
    accumulating in Chat even while you're looking at Workspace).
  * Emits a `wm` event whenever the focus changes, so the host can
    react if it wants (Lucifer might raise an inbound-message badge
    on Chat's tab, for instance).

The pager is a `/dis/wm/*` app on the same footing as `wm/acme` or
`wm/charon` — so it can be used by anyone, not just Lucifer. It's
the mobile equivalent of "tile three columns side-by-side" on
desktop: a layout primitive, not a UI feature.

### 3. Lucifer becomes a thin orchestrator on mobile

`lucifer.b`'s mobile path collapses to roughly:

```
if(mobile) {
    pager := load Pager Pager->PATH;  # /dis/wm/pager.dis
    pager->init(ctxt, "Lucifer");
    pager->addchild("Chat",      "/dis/luciconv.dis");
    pager->addchild("Workspace", "/dis/lucipres.dis");
    pager->addchild("Context",   "/dis/lucictx.dis");
    # Lucifer owns the header strip + task tiles only.
    # Pager owns layout, focus, swipe, repaint.
}
```

All the `KLUDGE-MOBILE-ACCORDION-INFR-119`-tagged code in `lucifer.b`
goes away: `zonerects()` mobile branch, `setexpandedzone`,
`drawmobiletitle`, `topexpandedzone`, the special mouse-routing in
mobile mode, the body-rect overlap trick, the title-bar-tap → switch
plumbing — all replaced by pager-internal mechanics.

Desktop Lucifer is unchanged: `mobile=0` still uses `zonerects()`'s
three-column layout and the existing wmsrv plumbing. The pager
exists but isn't loaded.

## Migration plan

This is a real refactor and wants to land in stages, each shippable on
its own (so we don't leave master broken for days).

### Stage A — Pager scaffold

  * Write `appl/wm/pager.b` with a placeholder UI: addchild() just
    keeps a list, the active child is drawn at the body rect with the
    others' sub-images hidden, tabs are drawn at the top.
  * Add `appl/wm/pager.m`, `mkfile`. Bundle in
    `build-android-apk.sh`'s asset staging.
  * Test on macOS desktop (since pager is platform-neutral): load
    pager → addchild ftree + clock + about → swipe tabs.
  * No Lucifer changes yet. Zero risk to mobile UX.

### Stage B — Make luciconv a wmclient

  * Convert `luciconv.b` from "load + spawn init with image" to
    "module called as a wm app with ctxt". Use `wmclient->window`
    and the standard wm channels.
  * Keep the existing direct-load entry point (the desktop path
    Lucifer uses now) behind a flag, so desktop continues working
    bit-for-bit.
  * Verify on desktop: Chat zone still works when loaded the old way;
    and now also works when loaded as a standalone wm app
    (`wm/luciconv` from the shell).

Repeat for `lucipres` then `lucictx`. After Stage B, each zone module
runs in two modes: legacy (Lucifer loads it as a library) and
standalone (any caller can `wm/luciconv` it).

### Stage C — Mobile Lucifer uses the pager

  * `lucifer.b`'s mobile branch instantiates the pager and asks it to
    host the three zone modules as standalone wm apps.
  * Remove the accordion code paths and the
    `KLUDGE-MOBILE-ACCORDION-INFR-119` markers. Mobile Lucifer
    becomes ~100 lines shorter.
  * Verify on Android + iOS that Chat / Workspace / Context all work
    as before, with smoother swipe transitions because the pager is
    a real wm primitive instead of a z-order kludge.

### Stage D — Legacy load path retired

  * Drop the dual-mode flag from Stage B. Both desktop and mobile
    Lucifer load the zone modules as standalone wm apps; the host
    differs only in *which layout it asks wm for* (three columns on
    desktop, pager on mobile).
  * Eventually the same machinery serves Acme + tile-three-ways on
    a desktop, but that's not part of this ticket.

## Risks and call-outs

  * **Wm churn on every swipe.** Pager has to ensure that hiding a
    child's sub-image doesn't cause its `presscr` (or equivalent) to
    shrink to 1×1 — exactly the bug PR #125's sentinels worked
    around, and PR #139 properly fixed in the iOS work. Pager keeps
    children at full body size, hidden by raise-other-to-top, not by
    resize. Carry the comment.

  * **Focus + IME.** On Android the soft keyboard depends on
    `SDL_StartTextInput`; today every tap re-arms it (also from PR
    #139's window of fixes). The pager must keep that semantics —
    forwarding mouse-down to the active child should trigger
    `SDL_StartTextInput` indirectly. Probably already fine, but
    worth a smoke test.

  * **wmclient's expectation of `wm` daemon.** `wmclient` talks to
    a `wm` process via the `wm` namespace; mobile Lucifer doesn't
    currently run a `wm` daemon — it manages sub-images directly.
    Stage A needs to verify that `wm` is running (or starts one)
    when the pager loads. If a `wm` process is too heavy for the
    phone, a leaner alternative is to have the pager itself BE a
    minimal wm-equivalent for its children (Stage A actually
    already does this).

  * **iOS parity.** If iOS picks up the pager via the same shared
    code (it will — pager is in shared appl/wm/), the iOS port
    benefits for free. But it needs the same swipe support — which
    iOS already has via INFR-121's shared draw-sdl3.c change.
    Verify two-finger swipe → pager switch on the iOS simulator at
    Stage C.

  * **Desktop regression.** Stage D is where desktop changes.
    Stage A-C explicitly preserve the desktop path bit-for-bit. The
    risk is concentrated at the Stage-D switchover; gate behind a
    fallback flag for one release cycle.

## What this proposal explicitly does NOT do

  * It does not change the Lucifer protocol (`/n/ui/activity/*` etc).
    The agent surface to Lucifer is unchanged.

  * It does not introduce per-child window decorations on mobile.
    The pager owns the tabs; children draw to their full body rect
    and never see a title bar of their own.

  * It does not block on the LLM/Veltro work (INFR-117). Pager + zones
    work without an LLM connected, same as today.

  * It does not replace `wmclient` or `wm` — it builds on them.

## Estimated work

  * Stage A — 1-2 days, mostly pager UX.
  * Stage B — 1-2 days per zone module, three zones, so 3-6 days.
  * Stage C — 1 day to wire Lucifer + remove kludge code.
  * Stage D — 1 day to retire the legacy load path + cleanup.

So ~6-10 working days for full INFR-119 completion. Probably wants to
be split across several PRs (one per stage), with the kludge code only
removed at Stage C.

## What's already in place that this builds on

  * **INFR-121 (PR #142):** swipe → wheel events in shared
    `draw-sdl3.c`. The pager's swipe-to-switch is the natural
    consumer of those wheel events on a horizontal track.
  * **INFR-138/139/140 (PR #139):** the resize-and-z-order bug fixes
    in `appl/cmd/lucifer.b` that made the current accordion stable
    enough to live with. Those make Stage A-C low-risk by removing
    the existing-app-window-loss class of failure.
  * **`wmclient` is already used by every wm app.** The Stage-B
    refactor of zone modules is well-trodden ground — `wm/acme`,
    `wm/charon`, `wm/ftree`, `wm/editor` are all reference
    implementations.

## Open questions for review

  1. **Pager-as-wm-daemon or pager-as-host-only?** Option A: pager
     spawns a real `wm` daemon and adopts standard wm/wmclient
     semantics. Option B: pager is itself the wm for its children
     (lighter, but less reusable outside Lucifer). Lean toward B for
     Stage A, with the understanding that promoting to A is a
     migration if we ever want a full wm on the phone.

  2. **Tab UI density.** With three children today, two-finger swipe
     +  tappable tabs both work. If/when a fourth zone appears, do
     we go to a hamburger? Pre-decide so the tab strip's layout
     budget is clear.

  3. **Should the pager be mobile-only at first?** Limiting the
     scope of Stage A. The desktop has its own column layout and
     doesn't need pager UX. Counter-argument: writing the pager so
     it works on desktop too (via the existing `wmsrv` mounts and
     the same `mousetrack` semantics) means desktop developers can
     test it locally without an Android device. Lean toward
     platform-neutral from the start.

## Out of scope but worth noting

  * Acme / Charon could eventually adopt the pager when running on a
    phone, getting tab-switch and swipe for free. Pager as a layout
    primitive enables that.
  * If a future iteration wants per-window animations (slide-in,
    fade), the pager is the right place to host them — children are
    unaffected.
