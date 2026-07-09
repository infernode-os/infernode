# Xenith Window Manipulation API

## Overview

Xenith provides a programmatic interface for AI agents and external programs to manipulate windows through the 9P filesystem at `/mnt/xenith`. This document describes the window manipulation capabilities, their implementation, and the security model that protects user-created windows.

## Justification

AI agents operating within Inferno need the ability to:

1. **Create windows** to display output, status, and results to the user
2. **Write content** to windows for communication
3. **Control layout** to organize information effectively (resize, reposition, arrange)
4. **Clean up** by deleting windows they created when done
5. **NOT interfere** with user-created windows

The traditional Acme/Xenith model treats all filesystem access equally. However, when AI agents can programmatically manipulate windows, we need a security boundary that prevents agents from accidentally or maliciously deleting user work while still allowing them to manage their own windows.

## Architecture

### Filesystem Interface

All window manipulation occurs through the 9P filesystem mounted at `/mnt/xenith`:

```
/mnt/xenith/
├── new/
│   └── ctl          # Write to create new window, returns window ID
├── index            # List of all windows
├── <id>/
│   ├── ctl          # Control commands (delete, grow, etc.)
│   ├── body         # Window body content
│   ├── tag          # Window tag line
│   ├── addr         # Address register
│   ├── data         # Data at address
│   ├── colors       # Per-window color overrides
│   └── event        # Event channel
└── ...
```

### Window Creation Tracking

Windows track their origin via the `creatormnt` field in the Window ADT:

```limbo
Window : adt {
    ...
    creatormnt : int;  # Mount session ID that created this window (0 = user/Xenith)
    ...
};
```

- `creatormnt = 0`: Window created by user (GUI, mouse clicks, keyboard)
- `creatormnt > 0`: Window created via `/mnt/xenith/new` filesystem interface

This field is set in `Xfid.walk()` when a window is created through the filesystem:

```limbo
Xfid.walk(x : self ref Xfid, cw: chan of ref Window)
{
    ...
    w = utils->newwindow(nil);
    w.settag();
    # Track which mount session created this window
    if(x.f != nil && x.f.mntdir != nil)
        w.creatormnt = x.f.mntdir.id;
    else
        w.creatormnt = 0;
    ...
}
```

## Features

### 1. Window Creation

**Command:** `cat /mnt/xenith/new/ctl`

Creates a new window and returns its ID.

**Implementation:** `xfid.b:Xfid.walk()` - Creates window via `utils->newwindow()` and sets `creatormnt` to track filesystem origin.

### 2. Content Writing

**Command:** `echo 'text' > /mnt/xenith/<id>/body`

Writes text to the window body.

**Implementation:** `xfid.b:Xfid.write()` - Standard Xenith body write mechanism.

### 3. Layout Control Commands

All layout commands are sent to `/mnt/xenith/<id>/ctl`:

| Command | Description | Implementation |
|---------|-------------|----------------|
| `grow` | Moderate size increase within column | `w.col.grow(w, 1, 0)` |
| `growmax` | Maximize within column (other windows shrink) | `w.col.grow(w, 2, 0)` |
| `growfull` | Take full column (hides other windows) | `w.col.grow(w, 3, 0)` |
| `moveto <y>` | Move to Y pixel position in current column | `w.col.close(w, FALSE); w.col.add(w, nil, y)` |
| `tocol <n> [<y>]` | Move to column N at optional Y position | Extract from old column, add to new |
| `newcol [<x>]` | Create new column at X position | `row.add(nil, xpos)` |

**Implementation:** `xfid.b:Xfid.ctlwrite()` - Parses commands and calls appropriate Column/Row methods.

#### grow/growmax/growfull

These leverage the existing `Column.grow()` method which accepts a "button" parameter:
- Button 1: Moderate growth (default interactive behavior)
- Button 2: Maximum growth within column
- Button 3: Full column takeover

#### moveto

Repositions a window within its current column:
1. Extract window from column without deleting: `w.col.close(w, FALSE)`
2. Re-add at new Y position: `w.col.add(w, nil, y)`

#### tocol

Moves a window to a different column:
1. Validate column index against `row.ncol`
2. Extract from old column: `oldcol.close(w, FALSE)`
3. Add to new column: `newcol.add(w, nil, yval)`

#### newcol

Creates a new column by calling `row.add(nil, xpos)`.

### 4. Window Deletion

**Command:** `echo delete > /mnt/xenith/<id>/ctl`

Deletes a window, subject to permission checks.

**Implementation:** `xfid.b:Xfid.ctlwrite()` with deletion protection:

```limbo
if(strncmp(p, "delete", 6) == 0){
    # Protect user-created windows from programmatic deletion
    if(x.f.mntdir != nil && w.creatormnt == 0){
        err = "permission denied: user window";
        break;
    }
    w.col.close(w, TRUE);
    m = 6;
}
```

### 5. Per-Window Colors

**File:** `/mnt/xenith/<id>/colors`

Allows setting custom colors for individual windows:

```
echo 'tagbg #1E1E2E' > /mnt/xenith/<id>/colors
echo 'bodyfg #CDD6F4' > /mnt/xenith/<id>/colors
echo 'reset' > /mnt/xenith/<id>/colors
```

**Keys:** `tagbg`, `tagfg`, `taghbg`, `taghfg`, `bodybg`, `bodyfg`, `bodyhbg`, `bodyhfg`, `bord`

### 6. Image Display

**Command:** `echo 'image <path>' > /mnt/xenith/<id>/ctl`

Displays an image in the window body area.

**Clear:** `echo 'clearimage' > /mnt/xenith/<id>/ctl`

## Security Model: Deletion Protection

### Design Goals

1. **Protect user work**: Windows created by the user (clicking New, opening files) cannot be deleted by programmatic access
2. **Allow agent cleanup**: Windows created via the filesystem API can be deleted by any mount session
3. **Simple implementation**: Single field tracking, minimal overhead

### Why This Approach

We considered tracking specific mount session IDs to allow only the creating session to delete a window. However, this fails because:

1. Each command execution from Xenith creates a **new mount session** via `fsysmount()`
2. An agent that creates a window in one command cannot delete it in the next (different session IDs)
3. Mount session IDs are transient and not meaningful across time

Instead, we use a binary distinction:
- `creatormnt == 0`: User-created, protected
- `creatormnt != 0`: Filesystem-created, deletable by any mount session

This allows agents to manage programmatically-created windows while protecting user work.

### Permission Check Flow

```
DELETE request arrives
    │
    ├─ Is request from mount session? (x.f.mntdir != nil)
    │   │
    │   ├─ YES: Is window user-created? (w.creatormnt == 0)
    │   │   │
    │   │   ├─ YES: DENY "permission denied: user window"
    │   │   │
    │   │   └─ NO: ALLOW (filesystem-created window)
    │   │
    │   └─ NO: ALLOW (internal Xenith operation)
    │
    └─ ALLOW
```

### Persistence Behavior

**The `creatormnt` field is NOT persisted across Dump/Load cycles.**

After loading a dump file:
- All windows have `creatormnt = 0`
- All windows are treated as user-created
- All windows are protected from programmatic deletion

This is intentional: after a restart, previous agent sessions no longer exist, so treating all windows as user-owned provides a clean security boundary.

## Files Modified

| File | Changes |
|------|---------|
| `appl/xenith/wind.m` | Added `creatormnt : int` field to Window ADT |
| `appl/xenith/xfid.b` | Added layout commands, deletion protection, creator tracking |
| `appl/nerv/agent.b` | Updated system prompt to document new capabilities |

## Usage Examples

### Agent Creating and Managing Windows

```sh
# Create a window
id=$(cat /mnt/xenith/new/ctl | awk '{print $1}')

# Write content
echo 'Hello World' > /mnt/xenith/$id/body

# Maximize it
echo growmax > /mnt/xenith/$id/ctl

# Move to column 0
echo 'tocol 0' > /mnt/xenith/$id/ctl

# Delete when done
echo delete > /mnt/xenith/$id/ctl
```

### Agent Attempting to Delete User Window

```sh
# Try to delete window 1 (user-created)
echo delete > /mnt/xenith/1/ctl
# Error: permission denied: user window
```

## Testing

See `tests/xenith-window-manipulation.sh` for regression tests covering:
- Window creation tracking
- Layout commands (grow, moveto, tocol, newcol)
- Deletion protection for user windows
- Deletion permission for filesystem-created windows
