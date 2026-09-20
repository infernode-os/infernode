/*
 * What os/virt's own files share with one another. The interface the
 * shared kernel is written against is ../arm64/fns.h; nothing outside
 * this directory includes this.
 */

/* uart.c */
int	consuartputc(Queue*, int);

/* fdt.c */
int	fdtvalid(void);
uintptr	fdtsize(void);
int	fdtmemory(uintptr*, uintptr*);
uchar*	fdtgetprop(char*, char*, int*);

/* random.c */
void	rnginit(void);

/* board.c */
void	boardwatchdogtick(void);
void	boardwatchdogpoll(void);
void	boardpoweroff(void);
ulong	rtcseconds(void);

Fbinfo*	boardfb(void);

/* blkvirtio.c: the blocks under #S -- ../port/devsd.c's contract */
void	blkvirtioinit(void);
int	sdblkread(uvlong, void*);
int	sdblkwrite(uvlong, void*);
int	sdblkpresent(void);
uvlong	sdblknblocks(void);

/* ethervirtio.c */
void	ethervirtiolink(void);

/* inputvirtio.c */
void	inputvirtioinit(void);

/* ramfb.c: a framebuffer, and fbcons.c's two questions about it */
int	ramfbinit(Fbinfo*);
void	fbfill(Fbinfo*, u32int);
int	fbdisplay(u32int);
int	fbvoffset(u32int, u32int);

/* ../arm64/fbcons.c and screen.c: the text console, the draw screen, the cursor */
int	fbconsinit(Fbinfo*);
int	fbconsadd(Fbinfo*);
int	fbconsscreens(void);
int	fbconsreleased(void);
int	fbconsvoff(void);
void	fbconsstop(void);
void	fbconsputs(char*, int);
void	swcursorat(int, int);
void	swcursorhide(void);
void	swcursorshow(void);
void	screendumpkey(void);
void	screenhexkey(void);

/* pciecam.c: the PCIe host bridge; ../port/pci.c above it */
void	pciecamlink(void);

/* ../port/usbxhcipci.c: xHCI controllers on the PCI bus, for devusb */
void	usbxhcipcilink(void);
