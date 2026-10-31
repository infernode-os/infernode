/*
 * The keyboard and the pointer: virtio input devices.
 *
 *	-device virtio-keyboard-device -device virtio-tablet-device
 *
 * A virtio input device is a stream of Linux evdev events -- eight
 * bytes each: a type, a code and a value -- arriving in buffers the
 * driver keeps posted on queue 0. A key is (EV_KEY, keycode, 1 down / 0
 * up); the tablet is (EV_ABS, axis, position) for each axis that
 * changed; and an EV_SYN closes each group, which is when a pointer
 * report is complete enough to pass on.
 *
 * The TABLET, not virtio-mouse. A mouse reports how far it moved, and
 * to do that QEMU has to capture the host's pointer; a tablet reports
 * WHERE it is, in a fixed 0..32767 range on each axis, so the guest's
 * cursor sits exactly under the host's, a window needs no grab, and a
 * test can say "click at 400,300" through QMP and mean it. Positions
 * are scaled to the screen here and handed to mousetrack as absolute.
 *
 * What the events become is what the board's input becomes: runes
 * through kbdputc into /dev/keyboard's queue, and mousetrack into
 * /dev/pointer. The window system cannot tell which machine it is on.
 *
 * WHERE THE KEYMAP LIVES is a decision, and this file makes the other
 * one from the board. There, keyboards are USB, the HID class is a
 * protocol with report descriptors and boot modes, and it lives in a
 * Limbo program (os/init/kbdusb.b) by this tree's rule that device
 * protocols stay outside the kernel. Here there is no protocol to keep
 * out: an event IS a keycode. So the table below is in the kernel, next
 * to the PL011's CR-to-NL, and is a transcription of kbdusb.b's -- same
 * runes for the same keys, Alt as the compose PREFIX rather than a
 * held modifier, the keypad always digits. If that division ever
 * chafes, the alternative is a device that serves raw events and a
 * Limbo program that reads them; nothing above would change.
 *
 * Events are handled in a kproc, not in the interrupt: mousetrack
 * redraws the software cursor under a lock that process-level drawing
 * also takes, and an interrupt that spun on it would never be let go.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "../port/error.h"
#include "board.h"
#include "virtio.h"

enum
{
	Ninput		= 4,		/* keyboards and tablets this will drive */
	Nevent		= 64,		/* event buffers kept posted, per device */

	/* event types */
	Evsyn		= 0,
	Evkey		= 1,
	Evrel		= 2,
	Evabs		= 3,

	Absx		= 0,
	Absy		= 1,
	Relwheel	= 8,

	Btnleft		= 0x110,
	Btnright	= 0x111,
	Btnmiddle	= 0x112,

	/* configuration space: write select and subsel, read size and the data */
	Cfgselect	= 0,
	Cfgsubsel	= 1,
	Cfgsize		= 2,
	Cfgdata		= 8,
	Cfgidname	= 0x01,
	Cfgabsinfo	= 0x12,

	/* the runes of module/keyboard.m that a keyboard can produce */
	Khome		= 0xE010,
	Kend		= 0xE011,
	Kup		= 0xE012,
	Kdown		= 0xE013,
	Kleft		= 0xE014,
	Kright		= 0xE015,
	Kpgup		= 0xE016,
	Kpgdown		= 0xE017,
	Kins		= 0xE063,
	Klatin		= 0xE06F,
	Kdel		= 0x7F,
	Kesc		= 0x1B,
};

typedef struct Event Event;
struct Event
{
	u16int	type;
	u16int	code;
	u32int	value;
};

typedef struct Input Input;
struct Input
{
	Vdev	*dev;
	Vq	*q;
	char	name[64];
	Event	ev[Nevent];	/* posted to the device, one per buffer */
	Rendez	r;
	int	work;

	/* keyboard state */
	int	shift, ctl, caps;

	/* pointer state: a report is built up until the EV_SYN */
	int	absmax[2];
	int	x, y, b;
	int	moved;
	int	wheel;
};

static Input inputs[Ninput];
static int ninput;

/*
 * Linux keycodes 0-111 to runes, unshifted and shifted. Zero is "no
 * rune": modifiers, locks and function keys. Letters are lower case
 * here and raised by shift or caps below.
 */
static Rune keymap[112] = {
[1]	Kesc, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b',
[15]	'\t', 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n',
[30]	'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
[43]	'\\', 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
[55]	'*',
[57]	' ',
[71]	'7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.',
[96]	'\n',
[98]	'/',
[102]	Khome, Kup, Kpgup, Kleft, Kright, Kend, Kdown, Kpgdown, Kins, Kdel,
};

static Rune keymapshift[112] = {
[2]	'!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+',
[26]	'{', '}',
[39]	':', '"', '~',
[43]	'|',
[51]	'<', '>', '?',
};

static void
keyevent(Input *in, int code, int value)
{
	Rune r;

	switch(code){
	case 42: case 54:			/* shift, either */
		in->shift = value != 0;
		return;
	case 29: case 97:			/* control, either */
		in->ctl = value != 0;
		return;
	case 58:				/* caps lock: toggles on the press */
		if(value == 1)
			in->caps ^= 1;
		return;
	case 56: case 100:			/* alt: the compose prefix, on the press */
		if(value == 1 && kbdq != nil)
			kbdputc(kbdq, Klatin);
		return;
	}
	if(value == 0 || code < 0 || code >= nelem(keymap))
		return;				/* a release, or a key with no rune */

	r = keymap[code];
	if(r == 0)
		return;
	if(r >= 'a' && r <= 'z'){
		if(in->shift ^ in->caps)
			r += 'A' - 'a';
	}else if(in->shift && keymapshift[code] != 0)
		r = keymapshift[code];
	if(in->ctl && r >= '@' && r < 0x7F)
		r &= 0x1F;			/* ^A is 1, ^[ is escape, ^? stays */
	if(kbdq != nil)
		kbdputc(kbdq, r);
}

static void
pointerevent(Input *in, Event *e)
{
	Fbinfo *fb;
	int bit, b;

	switch(e->type){
	case Evabs:
		fb = boardfb();
		if(fb == nil || e->code > Absy || in->absmax[e->code] <= 0)
			break;
		if(e->code == Absx)
			in->x = (vlong)e->value * fb->width / (in->absmax[Absx] + 1);
		else
			in->y = (vlong)e->value * fb->height / (in->absmax[Absy] + 1);
		in->moved = 1;
		break;
	case Evkey:
		bit = e->code == Btnleft ? 1 : e->code == Btnmiddle ? 2 : e->code == Btnright ? 4 : 0;
		if(e->value)
			in->b |= bit;
		else
			in->b &= ~bit;
		in->moved = 1;
		break;
	case Evrel:
		if(e->code == Relwheel)
			in->wheel = (int)e->value;
		break;
	case Evsyn:
		/*
		 * The wheel is buttons 8 (away) and 16 (toward) in Inferno,
		 * pressed and released in one breath: two reports.
		 */
		if(in->wheel != 0){
			b = in->b | (in->wheel > 0 ? 8 : 16);
			mousetrack(b, in->x, in->y, 0);
			in->wheel = 0;
			in->moved = 1;
		}
		if(in->moved)
			mousetrack(in->b, in->x, in->y, 0);
		in->moved = 0;
		break;
	}
}

static void
inputinterrupt(Ureg*, void *a)
{
	Input *in;

	in = a;
	if(virtiointr(in->dev) & 1){
		in->work = 1;
		wakeup(&in->r);
	}
}

static int
inputwork(void *a)
{
	return ((Input*)a)->work;
}

static void
inputproc(void *a)
{
	Input *in;
	Event *e, ev;
	Vbuf v;
	void *cookie;
	int posted;

	in = a;
	for(;;){
		sleep(&in->r, inputwork, in);
		in->work = 0;
		posted = 0;
		while(vqcollect(in->q, nil, &cookie) >= 0){
			e = cookie;
			if(e == nil)
				continue;
			ev = *e;
			/* the buffer goes straight back; the copy is what is handled */
			v.p = e;
			v.len = sizeof *e;
			v.write = 1;
			if(vqsubmit(in->q, &v, 1, e) >= 0)
				posted = 1;

			if(ev.type == Evkey && ev.code < Btnleft)
				keyevent(in, ev.code, ev.value);
			else
				pointerevent(in, &ev);
		}
		if(posted)
			vqkick(in->q);
	}
}

/* one configuration query: select, subsel, then size bytes of answer */
static int
inputcfg(Vdev *d, int sel, int subsel, uchar *buf, int n)
{
	uchar sz;

	virtiocfgwrite(d, Cfgselect, sel);
	virtiocfgwrite(d, Cfgsubsel, subsel);
	virtiocfgread(d, Cfgsize, &sz, 1);
	if(sz > n)
		sz = n;
	virtiocfgread(d, Cfgdata, buf, sz);
	return sz;
}

/*
 * Called from boardfbprobe, after the framebuffer: a pointer with no
 * screen to be scaled to has nowhere to point.
 */
void
inputvirtioinit(void)
{
	Input *in;
	Vdev *d;
	Vbuf v;
	uchar abs[20];
	int i, j, n;

	for(i = 0; ninput < Ninput && (d = virtiofind(Vidinput, i)) != nil; i++){
		in = &inputs[ninput];
		memset(in, 0, sizeof *in);
		in->dev = d;
		if(virtiostart(d, 0) < 0)
			continue;
		in->q = virtioqueue(d, 0, Nevent);
		if(in->q == nil){
			virtiofail(d);
			continue;
		}
		n = inputcfg(d, Cfgidname, 0, (uchar*)in->name, sizeof in->name - 1);
		in->name[n] = 0;

		/* an axis's range: min, max, fuzz, flat, resolution, 32 bits each, little-endian */
		for(j = Absx; j <= Absy; j++)
			if(inputcfg(d, Cfgabsinfo, j, abs, sizeof abs) >= 8)
				in->absmax[j] = abs[4] | abs[5]<<8 | abs[6]<<16 | abs[7]<<24;

		for(j = 0; j < Nevent; j++){
			v.p = &in->ev[j];
			v.len = sizeof in->ev[j];
			v.write = 1;
			if(vqsubmit(in->q, &v, 1, &in->ev[j]) < 0)
				break;
		}
		intrenable(d->irq, inputinterrupt, in, 0, "virtio-input");
		virtioready(d);
		vqkick(in->q);
		kproc("virtio-input", inputproc, in, 0);
		print("input: %s%s\n", in->name,
			in->absmax[Absx] > 0 ? " (absolute pointer)" : "");
		ninput++;
	}
	if(ninput == 0)
		print("input: no virtio keyboard or tablet\n");
}
