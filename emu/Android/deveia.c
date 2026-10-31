/*
 * Linux serial port definitions.  The ports are the host's, found when
 * the emulator starts, in this order: /dev/ttyS0 to the first
 * that is missing (as they always were, so eia0 is still ttyS0), then
 * every USB serial adapter and every USB modem-class device (GPS
 * receivers, microcontroller boards), /dev/ttyUSB0-7 and /dev/ttyACM0-7.
 * eiaNstatus names the host's device.  A device plugged in later is
 * found when the emulator is next started.
 */

#define	MAXDEV	24
static char *sysdev[MAXDEV];

static void _buildsysdev(void);
#define	buildsysdev()	_buildsysdev()	/* for deveia-posix.c */

#include <sys/ioctl.h>
#include "deveia-posix.c"
#include "deveia-bsd.c"


static struct tcdef_t bps[] = {
	{0,		B0},
	{50,		B50},
	{75,		B75},
	{110,		B110},
	{134,		B134},
	{150,		B150},
	{200,		B200},
	{300,		B300},
	{600,		B600},
	{1200,	B1200},
	{1800,	B1800},
	{2400,	B2400},
	{4800,	B4800},
	{9600,	B9600},
	{19200,	B19200},
	{38400,	B38400},
	{57600,	B57600},
	{115200,	B115200},
	{230400,	B230400},
	{460800,	B460800},
	{-1,		-1}
};

static void
_buildsysdev(void)
{
	static char *usb[] = { "/dev/ttyUSB%d", "/dev/ttyACM%d" };
	char name[32];
	struct stat sb;
	int i, j, n;

	if(sysdev[0] != nil)
		return;
	n = 0;
	for(i = 0; i < 8; i++){
		snprint(name, sizeof(name), "/dev/ttyS%d", i);
		if(stat(name, &sb) < 0)
			break;
		sysdev[n++] = strdup(name);
	}
	/* USB devices come and go: numbers can have gaps */
	for(i = 0; i < nelem(usb); i++)
		for(j = 0; j < 8 && n < MAXDEV; j++){
			snprint(name, sizeof(name), usb[i], j);
			if(stat(name, &sb) == 0)
				sysdev[n++] = strdup(name);
		}
}
