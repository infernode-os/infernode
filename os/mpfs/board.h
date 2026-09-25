/*
 * What this board's files share, and what the shared code
 * (../virtio/fdt.c, ../port/devsd.c, ../fb) asks of it.
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

/* the card: ../bcm/sdmmc.c's protocol over this board's controller, sd4hc.c */
#include "../port/sdio.h"
extern SDio sd4hcio;
#define	SDCARD_IO	sd4hcio
int	emmcinit(void);
char*	sdcontroller(void);
int	sdblkread(uvlong, void*);
int	sdblkwrite(uvlong, void*);
int	sdblkpresent(void);
uvlong	sdblknblocks(void);


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
