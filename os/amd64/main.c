/*
 * os/amd64 -- the first x86-64 stage: console, Multiboot map, and the
 * 9vm board when the boot loader offers one.
 *
 * A Multiboot boot loader enters the kernel in 32-bit protected mode
 * with a Multiboot information structure; boot.S enters long mode and
 * calls this.  The 16550 at 0x3F8 carries the console.  This file says
 * what the machine is, hands the 9vm #~ region to os/9vm, and stops.
 *
 * The next stages add os/port beneath this: the device layer, os/ip, the
 * Dis VM and the userland.  The ring smoke test runs only when the
 * command line contains "ringtest"; an ordinary boot just reports the
 * ring it found.
 */

#include <stdint.h>
#include <stddef.h>
#include "../9vm/board.h"

#define COM1		0x3F8
#define IDENTMAP	0x40000000u	/* boot.S identity-maps the first GiB */
#define MMAP_HOSTRING	0x9009u		/* 9vm's #~ region */

struct multiboot_info {
	uint32_t flags;
	uint32_t mem_lower;
	uint32_t mem_upper;
	uint32_t boot_device;
	uint32_t cmdline;
	uint32_t mods_count;
	uint32_t mods_addr;
	uint32_t syms[4];
	uint32_t mmap_length;
	uint32_t mmap_addr;
	uint32_t drives_length;
	uint32_t drives_addr;
	uint32_t config_table;
	uint32_t boot_loader_name;
	uint32_t apm_table;
	uint32_t vbe_control_info;
	uint32_t vbe_mode_info;
	uint16_t vbe_mode;
	uint16_t vbe_interface_seg;
	uint16_t vbe_interface_off;
	uint16_t vbe_interface_len;
} __attribute__((packed));

struct mmap_entry {
	uint32_t size;
	uint64_t addr;
	uint64_t len;
	uint32_t type;
} __attribute__((packed));

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

static void
serialinit(void)
{
	outb(COM1+1, 0x00);	/* interrupts off */
	outb(COM1+3, 0x80);	/* DLAB */
	outb(COM1+0, 0x01);	/* 115200 */
	outb(COM1+1, 0x00);
	outb(COM1+3, 0x03);	/* 8N1 */
	outb(COM1+2, 0xC7);	/* FIFO */
	outb(COM1+4, 0x0B);	/* DTR, RTS, OUT2 */
}

static void
putc(int c)
{
	while((inb(COM1+5) & 0x20) == 0)
		;
	outb(COM1, (uint8_t)c);
}

void
consprint(const char *s)
{
	while(*s != 0)
		putc(*s++);
}

void
consprinthex(uint64_t v)
{
	static const char dig[] = "0123456789abcdef";
	int i;

	consprint("0x");
	for(i = 60; i >= 0; i -= 4)
		putc(dig[(v >> i) & 15]);
}

void
consprintdec(uint64_t v)
{
	char buf[24];
	int i;

	i = 0;
	do {
		buf[i++] = '0' + v % 10;
		v /= 10;
	} while(v != 0);
	while(i > 0)
		putc(buf[--i]);
}

/* Is [pa, pa+len) inside the identity map boot.S builds? */
static int
inmap(uint64_t pa, uint64_t len)
{
	return pa != 0 && len <= IDENTMAP && pa <= IDENTMAP - len;
}

static int
contains(const char *s, const char *t)
{
	int i;

	for(; *s != 0; s++){
		for(i = 0; t[i] != 0 && s[i] == t[i]; i++)
			;
		if(t[i] == 0)
			return 1;
	}
	return 0;
}

static void
halt(void)
{
	consprint("infernode/amd64: halted\n");
	for(;;)
		__asm__ volatile("hlt");
}

void
main(uint32_t mbiaddr)
{
	struct multiboot_info *m;
	struct mmap_entry *e;
	Board board;
	char cmdbuf[256];
	const char *cmdline;
	uint8_t *p, *end;
	uint64_t ringpa, ringlen;

	serialinit();
	consprint("infernode/amd64: booting (Multiboot)\n");
	consprint("infernode/amd64: Multiboot at ");
	consprinthex(mbiaddr);
	consprint("\n");

	if(mbiaddr == 0 ||
	   (uint64_t)mbiaddr + sizeof(struct multiboot_info) > IDENTMAP){
		consprint("infernode/amd64: bad Multiboot information\n");
		halt();
	}
	m = (struct multiboot_info*)(uintptr_t)mbiaddr;
	consprint("infernode/amd64: flags ");
	consprinthex(m->flags);
	consprint("\n");
	if(m->flags & (1u<<0)){
		consprint("infernode/amd64: lower ");
		consprintdec(m->mem_lower);
		consprint(" KiB, upper ");
		consprintdec(m->mem_upper);
		consprint(" KiB\n");
	}
	/*
	 * The command line is optional and its pointer is only usable
	 * while it is inside the identity map boot.S builds.  Copy it, a
	 * byte at a time and only from mapped addresses, into a bounded
	 * buffer: contains() below scans this copy, so a loader that
	 * points outside the map or leaves the string unterminated costs
	 * a test, not a page fault.
	 */
	cmdline = 0;
	if((m->flags & (1u<<2)) && inmap(m->cmdline, 1)){
		int i;

		for(i = 0; i < 255; i++){
			if(!inmap((uint64_t)m->cmdline + i, 1))
				break;
			cmdbuf[i] = ((char*)(uintptr_t)m->cmdline)[i];
			if(cmdbuf[i] == 0)
				break;
		}
		cmdbuf[i] = 0;
		cmdline = cmdbuf;
		consprint("infernode/amd64: cmdline \"");
		consprint(cmdline);
		consprint("\"\n");
	}

	ringpa = 0;
	ringlen = 0;
	if((m->flags & (1u<<6)) && inmap(m->mmap_addr, m->mmap_length)){
		consprint("infernode/amd64: memory map\n");
		p = (uint8_t*)(uintptr_t)m->mmap_addr;
		end = p + m->mmap_length;
		while(p + 4 <= end){
			e = (struct mmap_entry*)p;
			if(e->size < 20 || p + 4 + e->size > end)
				break;
			consprint("  base ");
			consprinthex(e->addr);
			consprint(" len ");
			consprinthex(e->len);
			consprint(" type ");
			consprinthex(e->type);
			consprint("\n");
			if(e->type == MMAP_HOSTRING){
				ringpa = e->addr;
				ringlen = e->len;
			}
			p += 4 + e->size;
		}
	}

	if(ringpa == 0)
		consprint("infernode/amd64: no #~ host ring in the map\n");
	else if(boardattach(&board, ringpa, ringlen) == 0 &&
		cmdline != 0 && contains(cmdline, "ringtest"))
		ringselftest(&board);

	halt();
}
