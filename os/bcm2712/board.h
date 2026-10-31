/*
 * What this board's files share with one another. Nearly all of it is
 * the interface of the Broadcom family's drivers (../bcm), which both
 * those drivers and this board's code are written against, so it lives
 * with them; a declaration that is this board's alone goes below.
 */
#include "../bcm/bcm.h"

/* radio.c: ../bcm/ether4330.c's pins and power */
void	radiopins(void);
void	radiopower(int);
void	btpins(void);

/* rp1.c */
enum
{
	RP1intgpio0	= 0,
	RP1intgpio1	= 1,
	RP1intgpio2	= 2,
	RP1inteth	= 6,		/* Linux's dt-bindings/mfd/rp1.h */
	RP1intuart0	= 25,
	RP1intuart4	= 45,
	RP1intusb0	= 31,		/* host 0, interrupter 0 */
	RP1intusb1	= 36,
};
void	rp1link(void);
void	rp1intrenable(int, void (*)(Ureg*, void*), void*, int, char*);

/* rtcfan.c */
void	rtcfanlink(void);
vlong	rtcget(void);
int	rtcset(u32int);
void	fanset(int);
void	fanauto(int);
void	fanstart(void);
int	rtcbatt(void);
void	ledset(int);
int	buttonget(void);
int	fanget(void);
int	fanrpm(void);

/* pcie1.c, nvme.c */
int	pcie1up(void);
int	pcie1linked(void);
char*	pcie1speed(void);
void	pcie1slow(void);
void	nvmeslow(void);
u32int	pcie1cfgr(int);
void	pcie1cfgw(int, u32int);
void	nvmelink(void);
int	cmdlineword(char*);
int	nvmepresent(void);
vlong	nvmelength(void);
long	nvmerw(int, void*, long, vlong);
long	nvmestat(char*, long);

void	sdaddnvmepart(char*, vlong, vlong);

/* uartrp1.c */
void	rp1uartlink(void);

/* usbxhcirp1.c */
void	usbxhcirp1link(void);

/* etherrp1.c */
void	etherrp1link(void);
