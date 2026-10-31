# Dialogue Tiles

## Overview

Dialogue tiles are inline tiles in the Lucia conversation stream. They display status information (progress bars) or solicit operator input (Allow/Deny buttons). They are created and managed programmatically by lucibridge -- the LLM never sees them.

## Tile Types

### dialogue

Status/info tile with optional progress bar. Used for agent notifications (LLM setup, LLM unreachable, guided tour, agent stuck).

### form

Interactive tile with option buttons. Used for pre-tool approval (Allow/Deny). Blocks the agent until the operator responds.

## Protocol

Write to `/mnt/ui/activity/{id}/conversation/ctl`:

```
role=veltro dtype=dialogue title=Compacting progress=50 text=Summarizing...
role=veltro dtype=form title=Permission options=Allow,Deny text=exec rm -r /tmp
```

Update in-place:

```
update idx=N progress=100 title=Done
update idx=N options= title=Allowed
```

### Fields

| Field | Description |
|-------|-------------|
| `dtype` | `"dialogue"` or `"form"` |
| `title` | Tile heading |
| `progress` | 0-100 percentage (renders progress bar with theme progbg/progfg) |
| `options` | Comma-separated button labels |
| `text` | Body text |

## Architecture

- **luciuisrv.b**: Stores ConvMsg with dtype/title/progress/options. `hasattr()` handles Limbo's nil=="" string semantics for field clearing.
- **luciconv.b**: Renders tiles inline. Pass 1 estimates height (dialogue tiles are NOT markdown-rendered in Pass 2). Pass 3 draws title, body text, progress bar and buttons with its own drawing code (`drawdlgbutton()`). DlgButton array for click hit-testing.
- **lucibridge.b**: `writedialogue()`, `updatedialogue()`, `approver()`, `syncconvcount()`. `approver()` reads approval requests from the veltrosrv session's `approve` file, shows an Allow/Deny form, and writes the answer back.
- **veltrosrv.b**: decides which calls need approval (`needsapproval()`, `pretoolapproval()`) and emits the "Agent stuck" note after repeated failures.

## Programmatic Triggers

| Trigger | Type | When | Alert |
|---------|------|------|-------|
| Pre-tool approval | Form (Allow/Deny) | Destructive exec/write/edit | Urgency 2 (red flash) |
| Agent stuck | Dialogue (info) | Same tool fails 3x in a row (veltrosrv) | Urgency 1 (yellow flash) |

## Button Click Flow

1. User clicks button. `dlgbuttonclick()` writes the response to `conversation/input`.
2. `approver()` reads it (was blocking on input) and writes `allow` or `deny` to the session's `approve` file.
3. Tile updates: buttons disappear, title shows result ("Allowed"/"Denied").
4. No human message tile is created -- button clicks are programmatic, not user messages.
5. The LLM never sees the button response.

## Key Design Decisions

- Dialogue tiles are regular ConvMsg messages with extra fields -- no separate data structure.
- Buttons, title and progress bar are drawn directly by luciconv (DlgButton adt, theme colors progbg/progfg); no widget toolkit is involved.
- `syncconvcount()` prevents streaming placeholder index drift when dialogue tiles are injected.
- `sendinput()` does not `appendmsg` locally -- the server is authoritative for message store.
- `hasattr()` is needed because Limbo treats nil and `""` as identical for strings.

## File Locations

| File | Role |
|------|------|
| `appl/cmd/luciuisrv.b` | Protocol server -- ConvMsg storage, parsing, serialization |
| `appl/cmd/luciconv.b` | Rendering -- height estimation, drawing, button hit-testing |
| `appl/cmd/lucibridge.b` | Emitters -- writedialogue, updatedialogue, approver |
| `appl/veltro/veltrosrv.b` | Approval gate and failure-streak note |
