/*
 * What this board's files share, and what the shared drivers
 * (../virtio, ../port/devsd.c) ask of it.
 */

int	consuartputc(Queue*, int);

int	fdtvalid(void);
uintptr	fdtsize(void);
int	fdtmemory(uintptr*, uintptr*);
uchar*	fdtgetprop(char*, char*, int*);
int	fdtcpus(ulong*, int);

void	rnginit(void);

void	boardpoweroff(void);
ulong	rtcseconds(void);
void	boardmemory(uintptr*, uintptr*);
int	boardharts(ulong*, int);

Fbinfo*	boardfb(void);

void	blkvirtioinit(void);
int	sdblkread(uvlong, void*);
int	sdblkwrite(uvlong, void*);
int	sdblkpresent(void);
uvlong	sdblknblocks(void);

void	ethervirtiolink(void);

void	inputvirtioinit(void);

/* what ../fb/fbcons.c asks of a framebuffer; no display here yet */
void	fbfill(Fbinfo*, u32int);
int	fbdisplay(u32int);
int	fbvoffset(u32int, u32int);

/* ../fb/fbcons.c and screen.c: the text console, the draw screen, the cursor */
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
