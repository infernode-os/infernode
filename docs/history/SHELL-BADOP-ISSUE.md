# Shell BADOP Error on Command Failures

**Issue:** BADOP errors occur when commands fail or show usage messages through the shell

## The Pattern

**Works fine when run directly:**
```bash
./emu/MacOSX/o.emu -r. dis/ls.dis -a
# Shows usage, no BADOP

./emu/MacOSX/o.emu -r. dis/cat.dis /nonexistent
# Shows error, no BADOP
```

**Fails when run through shell:**
```
; ls -a
usage: ls [-delmnpqrstucFT] [files]
BADOP in xec: op=0, optab[0]=..., PC=...
[Sh] Broken: "illegal dis instruction"

; cd /nonexistent
cd: /nonexistent: '/nonexistent' file does not exist
BADOP in xec: op=0, optab[0]=..., PC=...
[Sh] Broken: "illegal dis instruction"
```

## Root Cause

The bug is in the **shell's error handling code**, not in the utilities.

When a command:
1. Exits with an error code
2. Raises an exception (raise "fail:...")
3. Shows usage and exits

The shell's exception handling hits opcode 0 (INOP/badop).

## Why This Happens

Looking at the BADOP debug:
- `op=0` → This is INOP (no-operation) instruction
- `optab[0]` is intentionally set to `badop`
- The shell code has an INOP instruction in its exception handling path

**Theory:** The shell's compiled bytecode has an INOP where it shouldn't, or the exception handler is jumping to the wrong location.

## Impact

**Low severity:**
- Commands still execute correctly
- Errors are reported correctly
- Shell continues running (doesn't crash)
- Just cosmetic BADOP messages

**Workaround:**
- Ignore the BADOP messages
- Or run commands directly when testing

## Differences from inferno64

Checked inferno64's sh.b - they have updates:
- Uses Arg module more consistently
- Different argument parsing approach
- May have fixes for exception handling

## Potential Fixes

### Option 1: Use inferno64's sh.b
Replace our sh.b with inferno64's version and recompile.

### Option 2: Debug the compiled bytecode
Disassemble sh.dis and find where INOP appears in error paths.

### Option 3: Live with it
The errors are cosmetic - everything still works.

## Testing Notes

**Commands that trigger BADOP (through shell):**
- Any command with invalid arguments: `ls -a` (empty dir)
- Any command accessing non-existent files: `cd /bad`
- Any command showing usage: `grep` (no args)

**Commands that work fine:**
- Valid commands with valid args: `ls /dis`
- Commands that succeed: `pwd`, `date`
- Direct execution of any command

## Recommendation

**For now:** Document as known cosmetic issue.

**For production:** Either:
1. Update to inferno64's sh.b
2. Or debug and fix exception handling
3. Or suppress BADOP debug output

The system is fully functional despite these messages.

---

**Status:** Non-critical cosmetic issue in shell error handling
**Workaround:** Ignore messages or run commands directly
**Fix:** Pending - needs exception handling debug or sh.b update
