#include "lib9.h"
#include <Windows.h>

static char	errstring[ERRMAX];

enum
{
	Magic = 0xffffff
};

static void
winerror(int e, char *buf, uint nerr)
{
	int r;
	wchar_t wbuf[ERRMAX];
	char buf2[ERRMAX], *p, *q;

	/*
	 * FormatMessageA returns the system error string in the user's
	 * default ANSI code page. On Russian Windows (CP1251), Polish
	 * (CP1250), Japanese (CP932) etc., the bytes coming back here are
	 * NOT UTF-8. Inferno is UTF-8 throughout, so the wrong bytes get
	 * passed up to the runtime and the user sees mojibake like
	 *   os: cannot exec: ┬А┬А ┬А┬А┬А┬А┬А┬А┬А ┬А┬А┬А┬А┬А.
	 * (sphynkx, GH #230). Use the W variant and convert the resulting
	 * UTF-16 to UTF-8 explicitly so the message is correct regardless
	 * of system locale.
	 */
	r = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM,
		0, e, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
		wbuf, sizeof(wbuf)/sizeof(wbuf[0]), 0);

	if(r == 0) {
		snprint(buf2, ERRMAX, "windows error %d", e);
	} else {
		/*
		 * WideCharToMultiByte with CP_UTF8 emits well-formed UTF-8.
		 * If the conversion overflows buf2, the result is truncated
		 * but still NUL-terminated by the explicit assignment below;
		 * the call's success/failure is then ignored because we have
		 * a fallback in place.
		 */
		int n = WideCharToMultiByte(CP_UTF8, 0, wbuf, -1,
			buf2, sizeof(buf2), 0, 0);
		if(n <= 0)
			snprint(buf2, ERRMAX, "windows error %d", e);
		else
			buf2[sizeof(buf2)-1] = '\0';
	}

	q = buf2;
	for(p = buf2; *p; p++) {
		if(*p == '\r')
			continue;
		if(*p == '\n')
			*q++ = ' ';
		else
			*q++ = *p;
	}
	*q = '\0';
	utfecpy(buf, buf+nerr, buf2);
}

void
werrstr(char *fmt, ...)
{
	va_list arg;

	va_start(arg, fmt);
	vseprint(errstring, errstring+sizeof(errstring), fmt, arg);
	va_end(arg);
	SetLastError(Magic);
}

int
errstr(char *buf, uint nerr)
{
	DWORD le;

	le = GetLastError();
	if(le == Magic)
		utfecpy(buf, buf+nerr, errstring);
	else
		winerror(le, buf, nerr);
	return 1;
}

void
oserrstr(char *buf, uint nerr)
{
	winerror(GetLastError(), buf, nerr);
}
