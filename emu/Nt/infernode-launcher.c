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
 * Compile:
 *   cl /O2 /Fe:InferNode.exe infernode-launcher.c /link /subsystem:windows
 */

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <stdio.h>

int WINAPI
WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance,
	LPSTR lpCmdLine, int nCmdShow)
{
	char exedir[MAX_PATH];   /* where InferNode.exe + o.emu.exe live */
	char rootdir[MAX_PATH];  /* where dis\, lib\ live (passed as -r) */
	char cmd[MAX_PATH * 4];
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
				"Expected dis\\ and lib\\ next to InferNode.exe,\n"
				"or two levels up (source checkout).",
				"InferNode", MB_OK | MB_ICONERROR);
			return 1;
		}
	}

	SetCurrentDirectoryA(rootdir);

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

	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);

	if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
			0, NULL, rootdir, &si, &pi)) {
		MessageBoxA(NULL,
			"Failed to start InferNode.\n\n"
			"Make sure o.emu.exe and SDL3.dll are present.",
			"InferNode", MB_OK | MB_ICONERROR);
		return 1;
	}

	/* Wait for emu to exit */
	WaitForSingleObject(pi.hProcess, INFINITE);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return 0;
}
