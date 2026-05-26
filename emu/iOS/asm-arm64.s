/*
 * arm64 low-level asm (test-and-set, FP save/restore, umult). Pure
 * Mach-O ARM64 ISA, identical to macOS; pull it in via the assembler's
 * .include directive (single source of truth, no .s preprocessing
 * needed). Path is relative to this file's directory (emu/iOS).
 */
	.include "../MacOSX/asm-arm64.s"
