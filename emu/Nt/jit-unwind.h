/*
 * emu/Nt/jit-unwind.h — Windows JIT SEH unwind registration.
 * See jit-unwind.c for the rationale (INFR-46).
 */
#ifndef INFERNODE_JIT_UNWIND_H
#define INFERNODE_JIT_UNWIND_H

#include <stddef.h>

/* First UNWIND_HEADER_SIZE bytes of every registered region are
 * reserved for the UNWIND_INFO struct. Callers must skip past it
 * when treating the region as code. */
#define JIT_UNWIND_HEADER_SIZE	16

/* JIT region kind — selects which UNWIND_INFO template is written.
 *
 * COMVEC_FRAME: code is entered with RSP already 48 bytes below caller's
 *   frame, with RSI, RDI, RBX, R12, R14, R15 saved there (this is the
 *   state comvec's prolog produces). Use for comvec itself AND for
 *   per-module JIT regions reached via JMP from comvec.
 *
 * LEAF: code is called directly from C with no prolog. Use for typecom
 *   init/destroy snippets that are invoked via a C function pointer.
 */
#define JIT_UNWIND_COMVEC_FRAME	1
#define JIT_UNWIND_LEAF		0

#ifdef __cplusplus
extern "C" {
#endif

int  jit_unwind_register(void *base, size_t length, int kind);
void jit_unwind_unregister(void *base);

#ifdef __cplusplus
}
#endif

#endif /* INFERNODE_JIT_UNWIND_H */
