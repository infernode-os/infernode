/*
 * os/amd64/io.h -- port I/O, and the delay the 8259 and 8254 want between
 * commands.
 */

#ifndef _OS_AMD64_IO_H_
#define _OS_AMD64_IO_H_

#include <stdint.h>

static inline void
outb(uint16_t port, uint8_t v)
{
	__asm__ volatile("outb %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint8_t
inb(uint16_t port)
{
	uint8_t v;

	__asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

static inline void
outw(uint16_t port, uint16_t v)
{
	__asm__ volatile("outw %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint16_t
inw(uint16_t port)
{
	uint16_t v;

	__asm__ volatile("inw %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

static inline void
outl(uint16_t port, uint32_t v)
{
	__asm__ volatile("outl %0, %1" : : "a"(v), "Nd"(port));
}

static inline uint32_t
inl(uint16_t port)
{
	uint32_t v;

	__asm__ volatile("inl %1, %0" : "=a"(v) : "Nd"(port));
	return v;
}

/* An I/O port write to an unused port is the traditional short delay. */
static inline void
io_wait(void)
{
	outb(0x80, 0);
}

#endif
