# 64-bit Alt Structure Alignment Fix

## Overview

This document describes a critical 64-bit porting bug discovered in InferNode's Dis VM interpreter, its root cause, discovery process, and the architecturally correct fix.

**Date:** January 2026
**Commit:** a429023
**Branch:** feature/sdl3-gui

---

## Symptom

Child GUI applications (wm/clock, wm/colors, acme) failed to create windows when launched from the window manager (wm/wm). The applications would:

1. Successfully open `/chan/wmctl` (the window manager control channel)
2. Block forever on the first read operation
3. Never receive their draw context from wmsrv

Meanwhile, wmsrv was correctly waiting in an alt statement for incoming requests, but the requests never arrived.

---

## Root Cause

A **32-bit/64-bit structure alignment mismatch** between the Limbo compiler and the C runtime interpreter.

### The Alt Structure

The `Alt` structure represents a Limbo `alt` statement (channel select operation). In C (`include/interp.h`):

```c
struct Alt {
    int     nsend;    // Number of send cases
    int     nrecv;    // Number of receive cases
    Altc    ac[1];    // Flexible array of channel cases
};
```

### The Limbo Compiler's Layout

In `limbo/com.c` (lines 1068-1071), the Limbo compiler generates alt tables using `IBY2WD` for field offsets:

```c
genmove(&altsrc, Mas, tint, sumark(mkconst(&altsrc, nsnd)), &slot);
off.val += IBY2WD;  // <-- Uses IBY2WD, not sizeof(int)!
genmove(&altsrc, Mas, tint, sumark(mkconst(&altsrc, nlab-nsnd)), &slot);
off.val += IBY2WD;
```

### The Mismatch

| Architecture | IBY2WD | sizeof(int) | nsend offset | nrecv offset (Limbo) | nrecv offset (C) |
|--------------|--------|-------------|--------------|----------------------|------------------|
| 32-bit       | 4      | 4           | 0            | 4                    | 4 ✓              |
| 64-bit       | 8      | 4           | 0            | 8                    | 4 ✗              |

On 64-bit:
- **Limbo** puts `nrecv` at offset 8 (using IBY2WD=8)
- **C runtime** reads `nrecv` from offset 4 (using sizeof(int)=4)
- Result: C always reads garbage (typically 0) for `nrecv`

### Consequence

When `xecalt()` executed, it would:
1. Read `a->nsend` correctly (offset 0, first 4 bytes = 0 for receive-only alts)
2. Read `a->nrecv` from offset 4, which was still in the padding of nsend = 0
3. Loop over 0 channels, find nothing ready, and block

This broke ALL alt statements in the system, causing file2chan reads to never reach wmsrv's Limbo channel.

---

## Discovery Process

### Step 1: Identify the Blocking Point

Added debug output to `csend()` in `emu/port/inferno.c`:

```c
iprint("CSEND: recv->prog=%p buf=%p size=%d\n",
    c->recv->prog, c->buf, c->size);
```

**Finding:** `recv->prog` was NULL even when wmsrv was supposedly waiting.

### Step 2: Trace the Alt Behavior

Added debug to `xecalt()` in `libinterp/alt.c`:

```c
print("ALT: a=%p a->nsend=%d a->nrecv=%d\n", a, a->nsend, a->nrecv);
```

**Finding:** ALL alts showed `nsend=0 nrecv=0`, even wmsrv's 3-channel alt.

### Step 3: Raw Memory Dump

Dumped the raw bytes at the Alt structure address:

```c
raw = (uchar*)a;
print("ALT: raw bytes: %02x %02x %02x %02x %02x %02x %02x %02x\n",
    raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7]);
print("ALT: raw bytes: %02x %02x %02x %02x %02x %02x %02x %02x\n",
    raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]);
```

**Output:**
```
ALT: raw bytes: 00 00 00 00 00 00 00 00  <- nsend (8 bytes, value=0)
ALT: raw bytes: 03 00 00 00 00 00 00 00  <- nrecv at offset 8! (value=3)
```

**Eureka:** The value 3 (wmsrv's 3 receive channels) was at offset 8, not offset 4!

### Step 4: Trace to Limbo Compiler

Examined `limbo/com.c` and found explicit use of `IBY2WD`:

```c
off.val += IBY2WD;  // Compiler uses IBY2WD for field spacing
```

And in `include/isa.h`:
```c
IBY2WD = sizeof(void*),  // 8 on 64-bit
```

---

## The Fix

Changed `include/interp.h`:

**Before (broken on 64-bit):**
```c
struct Alt {
    int     nsend;
    int     nrecv;
    Altc    ac[1];
};
```

**After (correct on all architectures):**
```c
struct Alt {
    WORD    nsend;  /* Must match IBY2WD in limbo compiler (pointer-sized) */
    WORD    nrecv;  /* Must match IBY2WD in limbo compiler (pointer-sized) */
    Altc    ac[1];
};
```

---

## Why This Is Architecturally Correct

### 1. WORD Is Already Pointer-Sized

In `include/interp.h`:
```c
typedef intptr_t WORD;  // Signed pointer-sized integer
```

This is the standard type used throughout InferNode for values that must match pointer size.

### 2. Matches Limbo Compiler Intent

The Limbo compiler explicitly uses `IBY2WD` (Inferno Bytes per Word) for alt table layout. Using `WORD` in C makes the runtime match the compiler's expectations.

### 3. Follows Existing Patterns

Other structures in the codebase already use `WORD` for similar cross-boundary data:
- `REG` structure fields
- Frame pointer offsets
- Module data layouts

### 4. Binary Compatibility

Pre-compiled `.dis` modules continue to work because:
- The layout is now correct (matches what Limbo compiler generated)
- No recompilation of Limbo code required

---

## Verification

After the fix:

```
$ timeout 20 ./o.emu -r../.. wm/wm wm/clock
SDL3: Using video driver: cocoa
```

No debug output, clean exit after timeout. Visual confirmation:
- Clock window appears
- Clock face renders (no hands - separate issue)
- Colors window works
- Acme launches and runs
- Menu system functional

---

## Lessons Learned

### 1. 64-bit Porting Requires Structure Auditing

Any structure shared between compiled bytecode and C runtime must be audited for:
- Field sizes matching the compiler's assumptions
- Alignment/padding differences between 32-bit and 64-bit

### 2. Raw Memory Dumps Are Essential

When structure field reads return unexpected values, dump the raw bytes. This immediately reveals alignment issues that symbolic debugging would obscure.

### 3. Follow the Compiler

When the bytecode format is defined by a compiler, trace through that compiler's code generation to understand the exact memory layout it produces.

### 4. Document Cross-Boundary Structures

Structures shared between Limbo bytecode and C runtime should have comments explaining:
- That they're cross-boundary
- Which compiler code defines the layout
- Which fields must be pointer-sized

---

## Related Files

- `include/interp.h` - Alt structure definition (THE FIX)
- `include/isa.h` - IBY2WD definition
- `libinterp/alt.c` - Alt execution (xecalt)
- `limbo/com.c` - Limbo compiler alt code generation
- `emu/port/inferno.c` - Channel send/receive (csend/crecv)

---

## Future Considerations

Other structures that may need similar auditing for 64-bit correctness:

1. `Altc` - Alt channel case structure
2. `Frame` - Stack frame structure
3. `Module` data layouts
4. Any structure where Limbo compiler uses `IBY2WD` for field offsets

A comprehensive audit of all cross-boundary structures would be valuable preventive maintenance.
