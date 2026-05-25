/*
 * iOS serial (eia) device — the first source that must diverge from
 * emu/MacOSX/ for Phase A.
 *
 * The macOS deveia.c enumerates host serial ports via IOKit
 * (<IOKit/IOKitLib.h>, IOMasterPort, ...), and IOKit is unavailable in
 * the iOS SDK. iOS shares Darwin's BSD termios, though, so we fork from
 * the portable BSD template (deveia-posix.c + deveia-bsd.c) exactly as
 * FreeBSD/Linux/Android do — no IOKit.
 *
 * A sandboxed iOS app has no host serial ports, so the sysdev[] entries
 * below are placeholders that simply never exist: the eia device loads
 * and presents zero usable ports, which is correct for Phase A (the
 * headless proof of life runs the Dis VM, 9P and Veltro, not serial).
 * The baud table is the Darwin-safe set (termios tops out at B230400).
 */

static char *sysdev[] = {
	"/dev/cu.serial0",
	"/dev/cu.serial1",
};

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
	{-1,		-1}
};
