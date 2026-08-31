/*
 * serialboot -- pull a kernel down the serial line and run it.
 *
 * Self-contained on purpose. It shares no code with the kernel: the
 * whole point is that it keeps working when the kernel does not, so a
 * bad kernel costs a reset rather than a trip to find the SD card
 * reader. That means its own PL011 setup, its own I/O, and no
 * dependency on anything under os/port.
 *
 * The protocol is deliberately dull:
 *
 *   board -> host   "\x03\x03\x03"     ready, send me something
 *   host  -> board  4 bytes, LE        image size
 *   board -> host   "OK" or "SZ"       accepted, or size refused
 *   host  -> board  <size> bytes       the image
 *   board -> host   "\r\nGO\r\n"       about to jump
 *
 * The handshake is repeated rather than sent once, so the host does not
 * have to win a race against reset: it can start listening whenever and
 * will see the next one.
 */

typedef unsigned int u32int;
typedef unsigned long long u64int;
typedef unsigned char uchar;

void jumpflush(void);

#define PHYSIO		0x3F000000UL
#define UARTREGS	(PHYSIO + 0x201000)
#define SYSTIMER	(PHYSIO + 0x003000)	/* free-running, 1MHz, no init */
#define GPIOREGS	(PHYSIO + 0x200000)

#define REG(a)		(*(volatile u32int*)(unsigned long)(a))

enum {
	Dr	= 0x00,		/* data */
	Fr	= 0x18,		/* flags */
	Ibrd	= 0x24,		/* integer baud divisor */
	Fbrd	= 0x28,		/* fractional baud divisor */
	Lcrh	= 0x2C,		/* line control */
	Cr	= 0x30,		/* control */
	Imsc	= 0x38,		/* interrupt mask */
	Icr	= 0x44,		/* interrupt clear */

	Txff	= 1<<5,		/* transmit FIFO full */
	Rxfe	= 1<<4,		/* receive FIFO empty */

	Fen	= 1<<4,		/* enable FIFOs */
	Wlen8	= 3<<5,
	Uarten	= 1<<0,
	Txe	= 1<<8,
	Rxe	= 1<<9,

	Clo	= 0x04,		/* system timer, low 32 bits */

	Kernel	= 0x80000,	/* where the boot ROM would have put it */

	/*
	 * A PREFIX BEFORE THE SIZE, and a timeout behind it.
	 *
	 * Without these this protocol cannot tell a size from anything
	 * else that happens to arrive: four bytes are read and believed.
	 * A host that sends a stray byte between the size and its
	 * intended value -- or a tool probing to see whether the loader
	 * is even there -- produces a number nobody meant, and the loader
	 * then sits reading that many bytes, swallowing everything sent
	 * to it including the probes used to ask whether it is alive.
	 * There is no kernel running to reset, so that is a trip to the
	 * power switch. It has cost two of them.
	 *
	 * The magic makes a size deliberate: bytes that are not the
	 * prefix are discarded rather than accumulated, so probing is
	 * safe by construction. The timeout makes a stall recoverable:
	 * a transfer that stops part way is abandoned and the loop
	 * starts again, so the loader talks again instead of waiting
	 * for bytes that are never coming.
	 */
	Magic0	= 0x1B,		/* ESC K R N -- not text, not CR, not ETX */
	Magic1	= 'K',
	Magic2	= 'R',
	Magic3	= 'N',
	Stalus	= 5000000,	/* give up on a stalled read after 5s */
	Maxsize	= 16*1024*1024,
};

static void
uartinit(void)
{
	u32int v;

	REG(UARTREGS + Cr) = 0;

	/* GPIO 14 and 15 to ALT0, which is TXD0/RXD0. */
	v = REG(GPIOREGS + 0x04);		/* GPFSEL1 */
	v &= ~((7u << 12) | (7u << 15));
	v |=  ((4u << 12) | (4u << 15));
	REG(GPIOREGS + 0x04) = v;

	REG(UARTREGS + Icr) = 0x7FF;

	/*
	 * 115200 from a 48MHz reference: 48000000/(16*115200) = 26.04,
	 * so 26 and 3/64. config.txt pins init_uart_clock to 48000000
	 * for exactly this reason -- the firmware, not this code,
	 * decides what the reference is.
	 */
	REG(UARTREGS + Ibrd) = 26;
	REG(UARTREGS + Fbrd) = 3;

	REG(UARTREGS + Lcrh) = Fen | Wlen8;
	REG(UARTREGS + Imsc) = 0;
	REG(UARTREGS + Cr) = Uarten | Txe | Rxe;
}

static void
putc(int c)
{
	while(REG(UARTREGS + Fr) & Txff)
		;
	REG(UARTREGS + Dr) = c;
}

static int
getc(void)
{
	while(REG(UARTREGS + Fr) & Rxfe)
		;
	return REG(UARTREGS + Dr) & 0xFF;
}

static u32int
now(void)
{
	return REG(SYSTIMER + Clo);
}

/*
 * A character, or -1 if none arrived within us microseconds.
 */
static int
getctmo(u32int us)
{
	u32int start;

	start = now();
	while((REG(UARTREGS + Fr) & Rxfe) != 0)
		if(now() - start > us)
			return -1;
	return REG(UARTREGS + Dr) & 0xFF;
}

static void
puts(char *s)
{
	while(*s)
		putc(*s++);
}

/*
 * Returns the address to jump to. Loops until it gets an image it is
 * willing to run: a refused size is not fatal, because the alternative
 * to asking again is a board that needs a power cycle to retry.
 */
unsigned long
bmain(void)
{
	u32int size, i;
	int c;
	uchar *p;

	uartinit();
	puts("\r\nserialboot: ready, waiting for a kernel\r\n");

	for(;;){
		putc(3); putc(3); putc(3);

		/*
		 * Wait for the prefix, discarding anything else.
		 *
		 * Blocking, because with nothing to load there is nothing
		 * else to do -- but every byte that is not the prefix is
		 * thrown away rather than kept, which is what makes it safe
		 * for a host to probe this line.
		 */
		if(getc() != Magic0)
			continue;
		if(getc() != Magic1)
			continue;
		if(getc() != Magic2)
			continue;
		if(getc() != Magic3)
			continue;

		size  = (u32int)getc();
		size |= (u32int)getc() << 8;
		size |= (u32int)getc() << 16;
		size |= (u32int)getc() << 24;

		if(size == 0 || size > Maxsize){
			puts("SZ");
			continue;
		}
		puts("OK");

		p = (uchar*)(unsigned long)Kernel;
		for(i = 0; i < size; i++){
			c = getctmo(Stalus);
			if(c < 0){
				/*
				 * Abandoned, not waited on for ever. The
				 * image is incomplete and jumping into it
				 * would be worse than saying so.
				 */
				puts("\r\nserialboot: transfer stalled\r\n");
				break;
			}
			p[i] = (uchar)c;
		}
		if(i < size)
			continue;

		puts("\r\nserialboot: GO\r\n");
		jumpflush();
		return Kernel;
	}
}
