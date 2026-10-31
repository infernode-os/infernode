/*
 *  I/O interface for usb XHCI controller.
 *
 *  9front's sys/src/9/port/usbxhci.h (MIT: Copyright © 2021 Plan 9
 *  Foundation, Copyright © 9front authors); the registers are volatile.
 */

typedef struct Xhci Xhci;
struct Xhci
{
	volatile u32int	*mmio;
	u64int	base;
	u64int	size;

	void	*aux;
	u64int	(*dmaaddr)(void*);

	Hci	*active;
};

Xhci* xhcialloc(volatile u32int *mmio, u64int base, u64int size);
void xhcihandoff(Xhci*);
void xhcilinkage(Hci *hp, Xhci *ctlr);

void xhciinit(Hci *hp);
void xhcishutdown(Hci *hp);
