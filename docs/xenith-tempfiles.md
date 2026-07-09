# Xenith/Acme Temporary File System

This document describes how Xenith and Acme manage temporary files for their
disk-backed buffer system in InferNode.

## Overview

Xenith and Acme use temporary files as a disk-backed swap/buffer system for
text data. This allows the editor to handle large files, maintain undo history,
and manage multiple windows without exhausting memory.

**This is standard Acme behavior** inherited from canonical Inferno. InferNode's
implementation differs only in where `/tmp` is located — it uses the host
filesystem rather than a memory filesystem.

## What Is Done

When Xenith or Acme starts, the `Disk.init()` function creates a temporary file:

```
/tmp/[A-Z]{pid}.{user}xenith    # For Xenith
/tmp/[A-Z]{pid}.{user}acme      # For Acme
/tmp/[A-Z]{pid}.{user}blks      # For diskblocks library
```

Where:
- `[A-Z]` is a slot letter (A through Z, giving 26 possible slots per process)
- `{pid}` is the Inferno process ID
- `{user}` is the first 4 characters of the username

Example: `/tmp/A42.pdfixenith`

This file serves as backing storage for the block allocator in `disk.b`:
- `Disk.write()` writes text buffer blocks to the file
- `Disk.read()` reads blocks back when needed
- `Disk.new()`/`Disk.release()` manage block allocation within the file

## How It Is Done

### 1. Profile Creates and Binds ~/tmp

The shell profile (`lib/sh/profile`) sets up the temporary directory:

```sh
# Create tmp directory if needed
if {! ftest -d $home/tmp} {
    mkdir -p $home/tmp
}

# Bind tmp to /tmp so applications can find it
bind -bc $home/tmp /tmp
```

On macOS/Linux, `$home` is the user's host home directory (e.g., `/Users/pdfinn`),
accessed through the `#U*` host filesystem device.

### 2. Xenith Creates Temp File

The `tempfile()` function in `disk.b` finds an available slot:

```limbo
tempfile() : ref Sys->FD
{
    buf := sys->sprint("/tmp/X%d.%.4sxenith", sys->pctl(0, nil), utils->getuser());
    for(i:='A'; i<='Z'; i++){
        buf[5] = i;
        (ok, nil) := sys->stat(buf);
        if(ok == 0)
            continue;           # File exists, try next slot
        fd := sys->create(buf, Sys->ORDWR|Sys->ORCLOSE, 8r600);
        if(fd != nil)
            return fd;
    }
    return nil;
}
```

Key flags:
- `ORDWR`: Read/write access
- `ORCLOSE`: Auto-delete file when file descriptor closes (normal exit cleanup)
- Mode `8r600`: Owner read/write only

### 3. Profile Cleans Stale Files

On startup, the profile removes stale temp files from previous crashed sessions:

```sh
# Clean up stale temp files from previous sessions
for f in /tmp/*.????xenith /tmp/*.????acme /tmp/*.????blks {
    rm $f >[2] /dev/null
}
```

The pattern `????` matches any 4-character username prefix.

## Why It Is Done

### Disk-Backed Buffers
Acme/Xenith can edit files larger than available memory by paging buffer
contents to disk.

### Undo History
Previous states of text buffers are stored in the temp file, enabling
unlimited undo without consuming proportional memory.

### Multiple Windows
Each window has its own buffers. With many windows open, the temp file
prevents memory exhaustion.

### ORCLOSE Auto-Cleanup
The `ORCLOSE` flag tells the kernel to delete the file when closed. On
normal exit, temp files vanish automatically. The profile cleanup handles
files left behind by crashes (where `ORCLOSE` never triggers).

### No OEXCL Flag
The `create()` call intentionally omits `OEXCL` (exclusive create) to match
canonical Acme behavior. Without `OEXCL`, if a stale file somehow exists
(race condition, filesystem edge case), `create()` truncates and reuses it
rather than failing.

## Debugging Tips

### "can't create temp file" Error

**Symptom:** Xenith exits immediately with "can't create temp file"

**Causes and Solutions:**

1. **~/tmp doesn't exist**
   ```bash
   # On host
   mkdir -p ~/tmp
   chmod 755 ~/tmp
   ```

2. **Permission denied on ~/tmp**
   ```bash
   # Check permissions
   ls -la ~/tmp
   # Fix if needed
   chmod 755 ~/tmp
   ```

3. **All 26 slots exhausted (same PID)**
   This is rare — would require 26 Xenith instances with identical PIDs.
   ```sh
   # Inside Inferno, clear stale files
   rm /tmp/*xenith /tmp/*acme /tmp/*blks
   ```

4. **Profile didn't run**
   If you launched emu without the shell profile:
   ```bash
   # Wrong - bypasses profile
   ./o.emu xenith
   
   # Correct - runs profile first
   ./o.emu -r../.. sh -l -c 'xenith -t dark'
   ```

### Stale Files Accumulating

**Symptom:** Many `*.????xenith` files in ~/tmp

**Cause:** Crashes or force-kills bypass `ORCLOSE` cleanup

**Solution:** Files are cleaned on next startup via profile. To clean manually:
```bash
# On host
rm ~/tmp/*xenith ~/tmp/*acme ~/tmp/*blks
```

### Checking Temp File Status

```sh
# Inside Inferno - list temp files
ls /tmp/*xenith /tmp/*acme /tmp/*blks

# On host - same files
ls ~/tmp/*xenith ~/tmp/*acme ~/tmp/*blks
```

### Verifying the Fix

To confirm the OEXCL fix is applied:
```bash
grep "sys->create" appl/xenith/disk.b appl/acme/disk.b appl/lib/diskblocks.b
```

Should show `ORDWR|ORCLOSE` without `OEXCL`:
```
appl/xenith/disk.b:    fd := sys->create(buf, Sys->ORDWR|Sys->ORCLOSE, 8r600);
appl/acme/disk.b:      fd := sys->create(buf, Sys->ORDWR|Sys->ORCLOSE, 8r600);
appl/lib/diskblocks.b: fd = sys->create(buf, Sys->ORDWR|Sys->ORCLOSE, 8r600);
```

## Difference from Canonical Inferno

| Aspect | Canonical Inferno | InferNode |
|--------|-------------------|-----------|
| `/tmp` location | Memory filesystem (ramfs) | Host filesystem (`~/tmp`) |
| Persistence | Lost on emu exit | Survives emu exit |
| Stale file risk | Low (memory cleared) | Higher (files persist) |
| Cleanup | Not needed | Profile cleans on startup |

InferNode uses the host filesystem for `/tmp` to integrate with the host
environment. The trade-off is that stale files can accumulate after crashes,
which is why the profile includes cleanup code.

## Architecture Notes

The temp file system involves three layers:

1. **Host Filesystem** (`#U*` device)
   - Provides access to macOS/Linux filesystem
   - Mounted at `/n/local` by profile

2. **Namespace Binding**
   - `~/tmp` bound to `/tmp` in Inferno namespace
   - Applications see `/tmp` as a normal directory

3. **Disk Module** (`disk.b`)
   - Creates temp file in `/tmp`
   - Manages block allocation within the file
   - Uses `ORCLOSE` for automatic cleanup

## Files Involved

- `lib/sh/profile` — Creates ~/tmp, binds to /tmp, cleans stale files
- `appl/xenith/disk.b` — Xenith disk buffer implementation
- `appl/acme/disk.b` — Acme disk buffer implementation  
- `appl/lib/diskblocks.b` — Shared diskblocks library
- `dis/xenith/disk.dis` — Compiled Xenith disk module
- `dis/acme/disk.dis` — Compiled Acme disk module
- `dis/lib/diskblocks.dis` — Compiled diskblocks module
