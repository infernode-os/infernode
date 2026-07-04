# Lucipres Presentation Rendering Architecture

## Status (2026-07-04): implemented

The refactor described below has landed (branch `claude/tk-reintegration-gwrqjx`):

- **Phase 0** — `appl/wm/presrender.b`: a standalone wmclient app that
  renders one presentation artifact (markdown/mermaid/image/pdf/code/
  text/table/diff) into its own window, lifted from lucipres.
- **Phase 1** — lucifer spawns a presrender peer per activity, feeds it
  presentation events in-process via `deliverevent()`, and z-orders its
  window like an app: raised when the current artifact is content
  (`showpresrender`), bottomed for apps/taskboard.  Single z-order
  authority is `enforcepreszorder()`.
- **Phase 2** — lucipres no longer draws content inline; it owns only the
  tab strip and the taskboard.  Content-area pointer input routes to
  presrender when content is centred.  Its window resizes with the zone.

Net effect: the presentation view is a **single-app view manager**.  The
content area always shows exactly one wmclient window — a real app
(editor/shell/fractal/wm), or the presrender content window — stacked by
one authority.  The dual-render (`lucipres draws inline` vs `lucifer
z-orders app windows`) path that caused the tab-switch z-order races is
gone.

### The old problem (for context)

lucipres had two rendering paths for tab content: app tabs got their own
wmclient windows (z-ordered by lucifer's preswmloop), while presentation
tabs were drawn directly into lucipres's own window image.  Switching
between the two required cross-process synchronisation with no ordering
guarantee — a race that showed as blank tabs, an app bleeding over a
slide, and ghost windows.

### Key implementation notes / gotchas

- **Event delivery must be in-process.**  presrender must NOT read the
  per-activity 9P event file itself: that event wakes only one reader, so
  it would steal `presentation current` from lucifer's nslistener.
  lucifer mirrors presentation events to presrender via
  `presrender_g->deliverevent(ev)` (guarded, non-blocking).
- **presrender join identity.**  preswmloop identifies presrender as the
  first non-lucipres join with no app-token mapping (`presrenderclient`).
- **z-order.**  `enforcepreszorder()` bottoms all apps + presrender, tops
  lucipres, then tops either the active app or (if `showpresrender`)
  presrender.  Called from handleprescurrent, the reshape allocation, and
  after resize.

## Remaining follow-up

- **Dead-code deletion in lucipres.**  The content render pipeline is now
  unused in lucipres (`renderart`, `renderartasync`/`renderdonech`,
  `drawrendimg`/`drawpdfnav`/`drawtable`/`drawdiff`/`drawfallbacktext`,
  `renderpdfpage`, `prescroll`/`handledrag`, the render-state Artifact
  fields, `backbuf`, and the `pdf`/`rlayout`/`renderer`/`render` includes
  + their init-time loads).  It compiles but is dead; deleting it shrinks
  lucipres and stops it loading a second copy of the render registry.
  Do this carefully — some text helpers (`splitlines`, `wraptext`, …) may
  still be shared with the taskboard/export paths.
- **Visual resize test.**  The resize path (`rszch`) reallocates
  presrender's window; it mirrors the app-resize handling but has only
  been exercised in fixed-geometry headless runs.  Verify on a real
  window resize / mobile accordion expand.
- **Scroll verification.**  Content-area input routes to presrender;
  verify scroll/pan/PDF-nav interactively on a long document.
