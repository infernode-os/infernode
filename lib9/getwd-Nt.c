#include "lib9.h"
#include <windows.h>

/*
 * The current directory as UTF-8, as every name in emu is ($emuwdir, from
 * which a launcher's file names are resolved).  GetCurrentDirectory into a
 * char buffer was the ANSI code page: a directory under C:\Users\José was
 * 0xE9 where UTF-8 has two bytes, and one with a letter in no code page was
 * '?'.  nil when it does not fit.
 */
char*
getwd(char *buf, int size)
{
	wchar_t w[4096];
	DWORD n;
	int m;
	char *p;

	if(size <= 0)
		return 0;
	buf[0] = 0;

	n = GetCurrentDirectoryW(nelem(w), w);
	if(n == 0 || n >= nelem(w))
		return 0;
	m = WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, size, NULL, NULL);
	if(m <= 0){
		buf[0] = 0;
		return 0;
	}

	for(p=buf; *p; p++)
		if(*p == '\\')
			*p = '/';

	return buf;
}
