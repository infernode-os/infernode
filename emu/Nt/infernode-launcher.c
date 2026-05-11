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
	char dir[MAX_PATH];
	char cmd[MAX_PATH * 2];
	STARTUPINFOA si;
	PROCESS_INFORMATION pi;

	(void)hInstance;
	(void)hPrevInstance;
	(void)lpCmdLine;
	(void)nCmdShow;

	/* Get directory containing this exe */
	GetModuleFileNameA(NULL, dir, MAX_PATH);
	{
		char *slash = strrchr(dir, '\\');
		if (slash) *slash = '\0';
	}

	SetCurrentDirectoryA(dir);

	/* Size window to 80% of the primary monitor, capped at 1920x1080 */
	{
		int sw = GetSystemMetrics(SM_CXSCREEN);
		int sh = GetSystemMetrics(SM_CYSCREEN);
		int w = sw * 80 / 100;
		int h = sh * 80 / 100;
		if (w > 1920) w = 1920;
		if (h > 1080) h = 1080;
		if (w < 800)  w = 800;
		if (h < 600)  h = 600;

		/* Launch InferNode emu with Lucifer GUI.
		 * -l sources lib/sh/profile (mounts host FS, overlay, secstore).
		 * The boot script starts luciuisrv, tools9p, lucibridge, lucifer. */
		_snprintf(cmd, sizeof(cmd),
			"\"%s\\o.emu.exe\" -g %dx%d"
			" -pheap=1024m -pmain=1024m -pimage=1024m"
			" -r . sh -l /dis/lucifer-start.sh",
			dir, w, h);
	}

	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);

	if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE,
			0, NULL, dir, &si, &pi)) {
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
