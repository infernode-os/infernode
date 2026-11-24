#define Unknown win_Unknown
#include	<windows.h>
#undef Unknown
#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	"keyboard.h"
#include	"cursor.h"

extern ulong displaychan;

extern void drawend(void);


extern	int	main(int argc, char **argv);

static	HINSTANCE	inst;
static	HINSTANCE	previnst;
static	int		cmdshow;
static	HWND		window;

static	char	*argv0 = "inferno";
static	ulong	*data;

extern	DWORD	PlatformId;
char*	gkscanid = "emu_win32vk";

/*
 * The entry point: both build scripts link with /ENTRY:wmainCRTStartup
 * (the console subsystem otherwise starts at main).  emu takes its
 * arguments as UTF-8, as every name in it is; main's argv is in the
 * ANSI code page, where a root of C:\Users\José\... was 0xE9, no UTF-8,
 * and "root path ... does not exist", and anything outside the code
 * page was '?' before emu saw it ("illegal root path"): a release
 * unpacked under an account name with an accent did not start.  The
 * process heap, not emu's pools, which are not set up before main.
 */
int
wmain(int argc, wchar_t **wargv)
{
	char **argv;
	int i, n;

	argv = HeapAlloc(GetProcessHeap(), 0, (argc+1)*sizeof(char*));
	if(argv == nil)
		return 1;
	for(i = 0; i < argc; i++){
		n = WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, nil, 0, nil, nil);
		argv[i] = HeapAlloc(GetProcessHeap(), 0, n > 0 ? n : 1);
		if(argv[i] == nil)
			return 1;
		if(n <= 0 || WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, argv[i], n, nil, nil) <= 0)
			argv[i][0] = '\0';
	}
	argv[argc] = nil;
	return main(argc, argv);
}

int WINAPI
WinMain(HINSTANCE winst, HINSTANCE wprevinst, LPSTR cmdline, int wcmdshow)
{
	inst = winst;
	previnst = wprevinst;
	cmdshow = wcmdshow;

	/* cmdline passed into WinMain does not contain name of executable.
	 * The globals __argc and __argv to include this info - like UNIX
	 */
	main(__argc, __argv);
	return 0;
}

void
dprint(char *fmt, ...)
{
	va_list arg;
	char buf[128];

	va_start(arg, fmt);
	vseprint(buf, buf+sizeof(buf), fmt, (LPSTR)arg);
	va_end(arg);
	OutputDebugString("inferno: ");
	OutputDebugString(buf);
}
