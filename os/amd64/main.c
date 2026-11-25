/*
 * os/amd64 -- the first x86-64 stage: console and the Multiboot map.
 *
 * A Multiboot boot loader enters the kernel in 32-bit protected mode
 * with a Multiboot information structure; boot.S enters long mode and
 * calls this.  The 16550 at 0x3F8 carries the console.  This file says
 * what the machine is and stops.
 *
 * The next stages add os/port beneath this: devices, os/ip, the Dis VM
 * and the userland.  The 9vm board -- the #~ host ring and the shared
 * display -- is a separate os/9vm stage.
 */

#include <stdint.h>
#include <stddef.h>

#define COM1		0x3F8
#define IDENTMAP	0x40000000u	/* boot.S identity-maps the first GiB */

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

static void
print(const char *s)
{
	while(*s != 0)
		putc(*s++);
}

static void
printhex(uint64_t v)
{
	static const char dig[] = "0123456789abcdef";
	int i;

	print("0x");
	for(i = 60; i >= 0; i -= 4)
		putc(dig[(v >> i) & 15]);
}

static void
printdec(uint64_t v)
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

static void
halt(void)
{
	print("infernode/amd64: halted\n");
	for(;;)
		__asm__ volatile("hlt");
}

void
main(uint32_t mbiaddr)
{
	struct multiboot_info *m;
	struct mmap_entry *e;
	uint8_t *p, *end;

	serialinit();
	print("infernode/amd64: booting (Multiboot)\n");
	print("infernode/amd64: Multiboot at ");
	printhex(mbiaddr);
	print("\n");

	if(mbiaddr == 0 ||
	   (uint64_t)mbiaddr + sizeof(struct multiboot_info) > IDENTMAP){
		print("infernode/amd64: bad Multiboot information\n");
		halt();
	}
	m = (struct multiboot_info*)(uintptr_t)mbiaddr;
	print("infernode/amd64: flags ");
	printhex(m->flags);
	print("\n");
	if(m->flags & (1u<<0)){
		print("infernode/amd64: lower ");
		printdec(m->mem_lower);
		print(" KiB, upper ");
		printdec(m->mem_upper);
		print(" KiB\n");
	}
	/*
	 * The command line is optional and its pointer is only usable
	 * while it is inside the identity map boot.S builds.  Read it a
	 * byte at a time, and only from mapped addresses: a loader that
	 * points outside the map, or leaves the string unterminated, must
	 * cost a diagnostic, not a page fault.
	 */
	if((m->flags & (1u<<2)) && inmap(m->cmdline, 1)){
		int i;

		print("infernode/amd64: cmdline \"");
		for(i = 0; i < 255; i++){
			if(!inmap((uint64_t)m->cmdline + i, 1))
				break;
			if(((char*)(uintptr_t)m->cmdline)[i] == 0)
				break;
			putc(((char*)(uintptr_t)m->cmdline)[i]);
		}
		print("\"\n");
	}

	if((m->flags & (1u<<6)) && inmap(m->mmap_addr, m->mmap_length)){
		print("infernode/amd64: memory map\n");
		p = (uint8_t*)(uintptr_t)m->mmap_addr;
		end = p + m->mmap_length;
		while(p + 4 <= end){
			e = (struct mmap_entry*)p;
			if(e->size < 20 || p + 4 + e->size > end)
				break;
			print("  base ");
			printhex(e->addr);
			print(" len ");
			printhex(e->len);
			print(" type ");
			printhex(e->type);
			print("\n");
			p += 4 + e->size;
		}
	}
	halt();
}
