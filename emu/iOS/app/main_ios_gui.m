/*
 * InferNode iOS GUI app entry — hellaphone Phase 2b.2.
 *
 * Unlike the headless shell (main_ios.m, which owns UIApplicationMain),
 * the GUI build lets SDL3 bootstrap UIKit: SDL_main.h renames our main()
 * to SDL_main and links SDL's real main(), which calls SDL_RunApp ->
 * UIApplicationMain on iOS and then invokes SDL_main on the UIKit main
 * thread. From there emu_run() does sdl3_preinit() (SDL_Init), libinit()
 * (emuinit/wm on a worker thread), and sdl3_mainloop() (this main thread).
 * SDL pumps the UIKit run loop inside SDL_PollEvent, so the desktop-style
 * loop coexists with UIKit. (If iOS rejects the busy loop we move to
 * SDL_MAIN_USE_CALLBACKS — see emu/iOS/README.md.)
 *
 * Boots -c0 (no JIT) against the Inferno root bundled at <App>.app/root,
 * via the mobile boot script the Android port introduced. chdir + "-r ."
 * dodges the MAXROOT(140) rootdir-buffer overflow (see main_ios.m).
 */

#import <Foundation/Foundation.h>
#include <SDL3/SDL_main.h>
#include <unistd.h>
#include <stdio.h>

extern int emu_run(int argc, char *argv[]);

int
main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;
	@autoreleasepool {
		NSString *root = [[[NSBundle mainBundle] resourcePath]
				stringByAppendingPathComponent:@"root"];
		if (chdir([root fileSystemRepresentation]) != 0)
			fprintf(stderr, "InferNode: chdir(%s) failed\n",
					[root fileSystemRepresentation]);

		/* emu's option parser (poolopt) writes into argv strings in
		 * place (it splits "-pheap=512m" on '='), so these must be
		 * MUTABLE — string literals live in read-only pages and a
		 * write there is a bus fault. Use stack-mutable char arrays. */
		char a_name[] = "InferNode";
		char a_c0[]   = "-c0";
		char a_ph[]   = "-pheap=512m";
		char a_pm[]   = "-pmain=256m";
		char a_pi[]   = "-pimage=256m";
		char a_r[]    = "-r";
		char a_dot[]  = ".";
		char a_sh[]   = "sh";
		char a_l[]    = "-l";
		char a_boot[] = "/lib/lucifer/boot-mobile.sh";
		char a_nolog[]= "--no-logon";
		char *av[] = {
			a_name, a_c0, a_ph, a_pm, a_pi, a_r, a_dot,
			a_sh, a_l, a_boot, a_nolog, NULL
		};
		int ac = (int)(sizeof(av) / sizeof(av[0])) - 1;

		fprintf(stderr, "InferNode GUI: emu_run booting lucifer (-c0), root=%s\n",
				[root fileSystemRepresentation]);
		return emu_run(ac, av);
	}
}
