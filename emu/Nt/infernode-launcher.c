/*
 * InferNode Windows Launcher
 *
 * Launches the InferNode emulator with Lucifer GUI.  Built as a Windows
 * GUI subsystem app so no console window flashes on double-click.
 *
 * LLM service (local llmsrv or remote 9P mount) is configured in
 * lib/sh/profile and managed via the Settings app — no external
 * process needed.
 *
 * Built with /DXENITH it is Xenith.exe instead: Xenith alone over the
 * emu window, as tools/xen runs it, started by lib/xen/boot.sh in the
 * user's profile directory, opening the files named on its command line
 * (Open With, or files dropped on it).  The profile mounts only C:\ at
 * /n/local, so files on other drives are passed over.
 *
 * Either launcher starts the emu with no console window and sends its
 * output to a log (XEN_LOG or %TEMP%\xen.log, as for xen; InferNode's
 * %TEMP%\infernode.log),
 * and says so in a message box when the emu fails to start or stops at
 * once: a missing DLL otherwise left nothing on the screen at all.
 *
 * Every path and the command line are UTF-16 (the W calls, wWinMain).
 * With the ANSI ones a release unpacked under a folder whose name has a
 * letter outside the code page (an account name in Chinese, Cyrillic,
 * Greek) came through as '?', and the emu could not find its root.  The
 * emu takes its arguments as UTF-16 too (emu/Nt/no_win.c's wmain).
 *
 * Compile (build-launcher.ps1 does both, with their resource scripts):
 *   cl /O2 /Fe:InferNode.exe infernode-launcher.c /link /subsystem:windows
 *   cl /O2 /DXENITH /Fe:Xenith.exe infernode-launcher.c /link /subsystem:windows
 */

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum { Npath = 1024 };	/* in wide characters: a longer path is refused, not cut */

#ifdef XENITH
#define NAME L"Xenith"

/*
 * Append s to the Inferno shell command at *p, raw or quoted for that
 * shell (wrapped in '' with any ' doubled, \ made /).  A Windows path
 * cannot hold ", so the whole command can go in "" on the emu's command
 * line.  Returns 0, appending nothing, when it does not fit.
 */
static int
add(wchar_t **p, wchar_t *e, const wchar_t *s, int quote)
{
	wchar_t *q = *p;

	if (quote)
		*q++ = L'\'';
	for (; *s != L'\0' && q < e - 2; s++) {
		wchar_t c = quote && *s == L'\\' ? L'/' : *s;
		*q++ = c;
		if (quote && c == L'\'')
			*q++ = L'\'';
	}
	if (*s != L'\0' || q >= e - 1) {
		**p = L'\0';
		return 0;
	}
	if (quote)
		*q++ = L'\'';
	*q = L'\0';
	*p = q;
	return 1;
}

/* C:\x\y -> /n/local/x/y; NULL for a path on any other drive. */
static const wchar_t *
inlocal(const wchar_t *path, wchar_t *buf, int n)
{
	wchar_t full[Npath];
	DWORD m;

	m = GetFullPathNameW(path, Npath, full, NULL);
	if (m == 0 || m >= Npath)
		return NULL;
	if ((full[0] != L'C' && full[0] != L'c') || full[1] != L':' || full[2] != L'\\')
		return NULL;
	if (_snwprintf(buf, n, L"/n/local%s", full + 2) < 0)
		return NULL;
	buf[n - 1] = L'\0';
	return buf;
}
#else
#define NAME L"InferNode"
#endif

/*
 * The emu's output, which a Windows-subsystem launcher has nowhere to
 * show: XEN_LOG or %TEMP%\xen.log for Xenith, as for xen, and
 * %TEMP%\infernode.log for InferNode, added to, between a line marking the start and one
 * giving the emu's exit status.  The handle is inherited by the emu.
 */
static HANDLE
openlog(wchar_t *path, int n)
{
	SECURITY_ATTRIBUTES sa;
	wchar_t tmp[Npath];
	const wchar_t *env;
	DWORD m;

#ifdef XENITH
	env = _wgetenv(L"XEN_LOG");
#else
	env = NULL;
#endif
	if (env != NULL && *env != L'\0')
		_snwprintf(path, n, L"%s", env);
	else {
		m = GetTempPathW(Npath, tmp);
		if (m == 0 || m >= Npath)
			wcscpy(tmp, L".\\");
#ifdef XENITH
		_snwprintf(path, n, L"%sxen.log", tmp);
#else
		_snwprintf(path, n, L"%sinfernode.log", tmp);
#endif
	}
	path[n - 1] = L'\0';

	memset(&sa, 0, sizeof(sa));
	sa.nLength = sizeof(sa);
	sa.bInheritHandle = TRUE;
	return CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
		&sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

/* s to the log, as UTF-8 */
static void
logline(HANDLE h, const wchar_t *s)
{
	static char buf[3 * 9000];
	DWORD w;
	int n;

	if (h == INVALID_HANDLE_VALUE)
		return;
	n = WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, sizeof(buf), NULL, NULL);
	if (n > 1)
		WriteFile(h, buf, (DWORD)(n - 1), &w, NULL);
}

static int
isdir(const wchar_t *path)
{
	DWORD attr = GetFileAttributesW(path);

	return attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY);
}

int WINAPI
wWinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
	LPWSTR lpCmdLine, int nCmdShow)
{
	static wchar_t cmd[8192];
	static wchar_t line[8192 + 64];
	wchar_t exedir[Npath];   /* where InferNode.exe + o.emu.exe live */
	wchar_t rootdir[Npath];  /* where dis\, lib\ live (passed as -r) */
	wchar_t probe[Npath];
	wchar_t logpath[Npath];
	STARTUPINFOW si;
	PROCESS_INFORMATION pi;
	HANDLE log = INVALID_HANDLE_VALUE, nul = INVALID_HANDLE_VALUE;
	ULONGLONG start;
	DWORD code, m;

	(void)hInstance;
	(void)hPrevInstance;
	(void)lpCmdLine;
	(void)nCmdShow;

	/* exedir = directory containing this exe (and o.emu.exe). */
	m = GetModuleFileNameW(NULL, exedir, Npath);
	if (m == 0 || m >= Npath) {
		MessageBoxW(NULL, L"The path of the folder " NAME L".exe is in is too long."
			L" Unpack the release somewhere with a shorter path.",
			NAME, MB_OK | MB_ICONERROR);
		return 1;
	}
	{
		wchar_t *slash = wcsrchr(exedir, L'\\');
		if (slash) *slash = L'\0';
	}

	/* Two supported layouts for the runtime tree:
	 *   1. Release bundle: InferNode.exe + o.emu.exe + dis\ + lib\ all
	 *      sit at the same level. rootdir == exedir.
	 *   2. Source checkout: this exe is at <repo>\emu\Nt\InferNode.exe
	 *      after build-launcher.ps1. dis\ and lib\ are two levels up at
	 *      <repo>. rootdir = exedir\..\.. (canonicalised).
	 *
	 * Probe for exedir\dis first; if missing, fall back to exedir\..\..
	 */
	_snwprintf(probe, Npath, L"%s\\dis", exedir);
	probe[Npath - 1] = L'\0';
	if (isdir(probe)) {
		wcsncpy(rootdir, exedir, Npath - 1);
		rootdir[Npath - 1] = L'\0';
	} else {
		wchar_t tmp[Npath];

		_snwprintf(tmp, Npath, L"%s\\..\\..", exedir);
		tmp[Npath - 1] = L'\0';
		_snwprintf(probe, Npath, L"%s\\dis", tmp);
		probe[Npath - 1] = L'\0';
		m = 0;
		if (isdir(probe))
			m = GetFullPathNameW(tmp, Npath, rootdir, NULL);
		if (m == 0 || m >= Npath) {
			/* Most often: run from inside the zip in Explorer, which
			 * copies this one file to a temporary folder. */
			MessageBoxW(NULL,
				L"Could not find the rest of " NAME L" (its dis and lib folders).\n\n"
				L"If you opened " NAME L".exe from inside the zip, extract the whole"
				L" zip first (right-click it, Extract All), then run " NAME L".exe"
				L" from the folder it makes.",
				NAME, MB_OK | MB_ICONERROR);
			return 1;
		}
	}

#ifdef XENITH
	{
		static wchar_t sh[6144];
		wchar_t buf[Npath + 16], *p = sh, *e = sh + 6144;
		const wchar_t *home = _wgetenv(L"USERPROFILE");
		const wchar_t *geom = _wgetenv(L"XEN_GEOM");
		const wchar_t *f;
		int i;

		sh[0] = L'\0';
		if (home != NULL && (f = inlocal(home, buf, Npath + 16)) != NULL) {
			add(&p, e, L"cd ", 0);
			add(&p, e, f, 1);
			add(&p, e, L" >[2] /dev/null; ", 0);
		}
		add(&p, e, L"run /lib/xen/boot.sh -t xenith", 0);
		for (i = 1; i < __argc; i++) {
			if ((f = inlocal(__wargv[i], buf, Npath + 16)) == NULL)
				continue;
			if (!add(&p, e, L" ", 0) || !add(&p, e, f, 1))
				break;
		}

		/* The window's title; o.emu.exe inherits it. */
		SetEnvironmentVariableW(L"SDL_APP_NAME", L"Xenith");

		/* -l sources lib/sh/profile; /lib/xen/boot.sh starts the
		 * plumber, the model and Xenith, as tools/xen does. */
		_snwprintf(cmd, 8192,
			L"\"%s\\o.emu.exe\" -c1 -g %s"
			L" -pheap=512m -pmain=512m -pimage=512m"
			L" -r \"%s\" /dis/sh.dis -l -c \"%s\"",
			exedir, geom != NULL ? geom : L"1400x900", rootdir, sh);
		cmd[8191] = L'\0';
	}
#else
	/* Use the full screen resolution */
	{
		int w = GetSystemMetrics(SM_CXSCREEN);
		int h = GetSystemMetrics(SM_CYSCREEN);

		/* -l sources lib/sh/profile; /lib/lucifer/boot.sh is the
		 * unified GUI boot script shared with macOS/Linux. */
		_snwprintf(cmd, 8192,
			L"\"%s\\o.emu.exe\" -c1 -g %dx%d"
			L" -pheap=1024m -pmain=1024m -pimage=1024m"
			L" -r \"%s\" sh -l /lib/lucifer/boot.sh",
			exedir, w, h, rootdir);
		cmd[8191] = L'\0';
	}

#endif

	/* After the file names are made full, from the caller's directory. */
	SetCurrentDirectoryW(rootdir);

	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);

	/*
	 * o.emu.exe is a console program: started from here with no
	 * console of our own, Windows would open a terminal window beside
	 * the emu's.  CREATE_NO_WINDOW gives it a console with no window,
	 * and its output goes to the log.  Its keyboard thread reads NUL,
	 * gets end of file at once and exits; the SDL window has the keys.
	 */
	{
		SECURITY_ATTRIBUTES sa;
		SYSTEMTIME t;

		log = openlog(logpath, Npath);
		memset(&sa, 0, sizeof(sa));
		sa.nLength = sizeof(sa);
		sa.bInheritHandle = TRUE;
		nul = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
			&sa, OPEN_EXISTING, 0, NULL);
		if (log != INVALID_HANDLE_VALUE && nul != INVALID_HANDLE_VALUE) {
			si.dwFlags = STARTF_USESTDHANDLES;
			si.hStdInput = nul;
			si.hStdOutput = log;
			si.hStdError = log;
		}
		GetLocalTime(&t);
		_snwprintf(line, 8192 + 64,
			L"--- " NAME L" %04d-%02d-%02d %02d:%02d:%02d: %s\r\n",
			t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond, cmd);
		line[8192 + 63] = L'\0';
		logline(log, line);
	}

	start = GetTickCount64();
	if (!CreateProcessW(NULL, cmd, NULL, NULL, TRUE,
			CREATE_NO_WINDOW, NULL, rootdir, &si, &pi)) {
		MessageBoxW(NULL,
			L"Failed to start " NAME L".\n\n"
			L"Make sure o.emu.exe and SDL3.dll are present.",
			NAME, MB_OK | MB_ICONERROR);
		return 1;
	}

	/* Wait for emu to exit */
	WaitForSingleObject(pi.hProcess, INFINITE);
	if (!GetExitCodeProcess(pi.hProcess, &code))
		code = 0;
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	{
		wchar_t end[64];

		_snwprintf(end, 64, L"--- exit status 0x%08lx\r\n", (unsigned long)code);
		end[63] = L'\0';
		logline(log, end);
	}
	if (log != INVALID_HANDLE_VALUE)
		CloseHandle(log);
	if (nul != INVALID_HANDLE_VALUE)
		CloseHandle(nul);

	/*
	 * A failure the user would otherwise never see: the emu could not
	 * load (a DLL missing: the window never opens), faulted, or gave up
	 * at once.  A normal exit (Exit, closing the window) is 0; one ended
	 * from outside (Task Manager's 1, Stop-Process's -1) after it had
	 * started is not a failure to report.
	 */
	if ((code >= 0xC0000000UL && code != 0xFFFFFFFFUL) ||
	    (code != 0 && GetTickCount64() - start < 10000)) {
		wchar_t msg[Npath + 512];
		const wchar_t *why;

		switch (code) {
		case 0xC0000135UL:	/* STATUS_DLL_NOT_FOUND */
			why = L"A DLL that o.emu.exe needs is missing. Unpack the whole"
				L" release zip again, keeping every .dll beside o.emu.exe.";
			break;
		case 0xC0000139UL:	/* STATUS_ENTRYPOINT_NOT_FOUND */
		case 0xC000007BUL:	/* STATUS_INVALID_IMAGE_FORMAT */
			why = L"A DLL beside o.emu.exe is the wrong version or not 64-bit."
				L" Unpack the whole release zip again.";
			break;
		default:
			why = L"The emulator stopped.";
			break;
		}
		_snwprintf(msg, Npath + 512,
			NAME L" stopped (exit status 0x%08lx).\n\n%s\n\nIts output is in\n%s",
			(unsigned long)code, why, logpath);
		msg[Npath + 511] = L'\0';
		MessageBoxW(NULL, msg, NAME, MB_OK | MB_ICONERROR);
		return 1;
	}

	return 0;
}
