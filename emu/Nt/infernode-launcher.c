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
 * Compile (build-launcher.ps1 does both, with their resource scripts):
 *   cl /O2 /Fe:InferNode.exe infernode-launcher.c /link /subsystem:windows
 *   cl /O2 /DXENITH /Fe:Xenith.exe infernode-launcher.c /link /subsystem:windows
 */

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <stdio.h>
#include <stdlib.h>

#ifdef XENITH
#define NAME "Xenith"

/*
 * Append s to the Inferno shell command at *p, raw or quoted for that
 * shell (wrapped in '' with any ' doubled, \ made /).  A Windows path
 * cannot hold ", so the whole command can go in "" on the emu's command
 * line.  Returns 0, appending nothing, when it does not fit.
 */
static int
add(char **p, char *e, const char *s, int quote)
{
	char *q = *p;

	if (quote)
		*q++ = '\'';
	for (; *s != '\0' && q < e - 2; s++) {
		char c = quote && *s == '\\' ? '/' : *s;
		*q++ = c;
		if (quote && c == '\'')
			*q++ = '\'';
	}
	if (*s != '\0' || q >= e - 1) {
		**p = '\0';
		return 0;
	}
	if (quote)
		*q++ = '\'';
	*q = '\0';
	*p = q;
	return 1;
}

/* C:\x\y -> /n/local/x/y; NULL for a path on any other drive. */
static const char *
inlocal(const char *path, char *buf, int n)
{
	char full[MAX_PATH];

	if (GetFullPathNameA(path, sizeof(full), full, NULL) == 0)
		return NULL;
	if ((full[0] != 'C' && full[0] != 'c') || full[1] != ':' || full[2] != '\\')
		return NULL;
	_snprintf(buf, n, "/n/local%s", full + 2);
	buf[n - 1] = '\0';
	return buf;
}
#else
#define NAME "InferNode"
#endif

int WINAPI
WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
	LPSTR lpCmdLine, int nCmdShow)
{
	char exedir[MAX_PATH];   /* where InferNode.exe + o.emu.exe live */
	char rootdir[MAX_PATH];  /* where dis\, lib\ live (passed as -r) */
	char cmd[8192];
	char probe[MAX_PATH];
	DWORD attr;
	STARTUPINFOA si;
	PROCESS_INFORMATION pi;

	(void)hInstance;
	(void)hPrevInstance;
	(void)lpCmdLine;
	(void)nCmdShow;

	/* exedir = directory containing this exe (and o.emu.exe). */
	GetModuleFileNameA(NULL, exedir, MAX_PATH);
	{
		char *slash = strrchr(exedir, '\\');
		if (slash) *slash = '\0';
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
	_snprintf(probe, sizeof(probe), "%s\\dis", exedir);
	attr = GetFileAttributesA(probe);
	if (attr != INVALID_FILE_ATTRIBUTES &&
			(attr & FILE_ATTRIBUTE_DIRECTORY)) {
		strncpy(rootdir, exedir, MAX_PATH - 1);
		rootdir[MAX_PATH - 1] = '\0';
	} else {
		char tmp[MAX_PATH];
		_snprintf(tmp, sizeof(tmp), "%s\\..\\..", exedir);
		_snprintf(probe, sizeof(probe), "%s\\dis", tmp);
		attr = GetFileAttributesA(probe);
		if (attr != INVALID_FILE_ATTRIBUTES &&
				(attr & FILE_ATTRIBUTE_DIRECTORY)) {
			GetFullPathNameA(tmp, MAX_PATH, rootdir, NULL);
		} else {
			MessageBoxA(NULL,
				"Could not find Inferno runtime tree.\n\n"
				"Expected dis\\ and lib\\ next to " NAME ".exe,\n"
				"or two levels up (source checkout).",
				NAME, MB_OK | MB_ICONERROR);
			return 1;
		}
	}

#ifdef XENITH
	{
		char sh[6144], buf[MAX_PATH + 16], *p = sh, *e = sh + sizeof(sh);
		const char *home = getenv("USERPROFILE");
		const char *geom = getenv("XEN_GEOM");
		const char *f;
		int i;

		sh[0] = '\0';
		if (home != NULL && (f = inlocal(home, buf, sizeof(buf))) != NULL) {
			add(&p, e, "cd ", 0);
			add(&p, e, f, 1);
			add(&p, e, " >[2] /dev/null; ", 0);
		}
		add(&p, e, "run /lib/xen/boot.sh -t xenith", 0);
		for (i = 1; i < __argc; i++) {
			if ((f = inlocal(__argv[i], buf, sizeof(buf))) == NULL)
				continue;
			if (!add(&p, e, " ", 0) || !add(&p, e, f, 1))
				break;
		}

		/* -l sources lib/sh/profile; /lib/xen/boot.sh starts the
		 * plumber, the model and Xenith, as tools/xen does. */
		_snprintf(cmd, sizeof(cmd),
			"\"%s\\o.emu.exe\" -c1 -g %s"
			" -pheap=512m -pmain=512m -pimage=512m"
			" -r \"%s\" /dis/sh.dis -l -c \"%s\"",
			exedir, geom != NULL ? geom : "1400x900", rootdir, sh);
		cmd[sizeof(cmd) - 1] = '\0';
	}
#else
	/* Use the full screen resolution */
	{
		int w = GetSystemMetrics(SM_CXSCREEN);
		int h = GetSystemMetrics(SM_CYSCREEN);

		/* -l sources lib/sh/profile; /lib/lucifer/boot.sh is the
		 * unified GUI boot script shared with macOS/Linux. */
		_snprintf(cmd, sizeof(cmd),
			"\"%s\\o.emu.exe\" -c1 -g %dx%d"
			" -pheap=1024m -pmain=1024m -pimage=1024m"
			" -r \"%s\" sh -l /lib/lucifer/boot.sh",
			exedir, w, h, rootdir);
	}

#endif

	/* After the file names are made full, from the caller's directory. */
	SetCurrentDirectoryA(rootdir);

	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);

	if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
			0, NULL, rootdir, &si, &pi)) {
		MessageBoxA(NULL,
			"Failed to start " NAME ".\n\n"
			"Make sure o.emu.exe and SDL3.dll are present.",
			NAME, MB_OK | MB_ICONERROR);
		return 1;
	}

	/* Wait for emu to exit */
	WaitForSingleObject(pi.hProcess, INFINITE);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return 0;
}
