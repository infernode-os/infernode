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
#include <ftw.h>
#include <sys/stat.h>

extern int emu_run(int argc, char *argv[]);

/* nftw callback: make the copied root writable so the boot can create
 * /n, /tmp, /usr, etc.
 *
 * Two reasons it isn't already: (1) the bundle is code-signed read-only
 * and copyItemAtPath preserves those perms; (2) more subtly, emu runs as
 * Inferno user eve="inferno" (getpwuid fails in the iOS sandbox), which
 * doesn't match the copied files' host owner, so Inferno's 9P permission
 * check uses the "other" bits. World-writable dirs (0777) therefore let
 * the boot write. Acceptable here: the tree lives in the app's private,
 * sandboxed container. A cleaner fix (Phase B2) makes os.c default eve
 * to the file owner so 0755 suffices. */
static int
mk_writable(const char *p, const struct stat *sb, int typeflag, struct FTW *ftw)
{
	(void)typeflag;
	(void)ftw;
	chmod(p, S_ISDIR(sb->st_mode) ? 0777 : 0666);
	return 0;
}

/*
 * The Inferno root is bundled read-only in the .app, but the boot must
 * create writable dirs (/n for the UI 9P mount, /tmp, /usr, ...). So on
 * launch, copy the bundled root into the app's writable Caches container
 * and run emu from there. Fresh copy each launch so a rebuilt bundle
 * takes effect (a later optimisation can symlink the read-only dis/lib/
 * fonts and only copy the writable mountpoints). Returns a strdup'd path.
 */
static char *
prepare_writable_root(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *src = [[[NSBundle mainBundle] resourcePath]
			stringByAppendingPathComponent:@"root"];
	NSString *dst = [[NSSearchPathForDirectoriesInDomains(
			NSCachesDirectory, NSUserDomainMask, YES) firstObject]
			stringByAppendingPathComponent:@"inferno"];
	[fm removeItemAtPath:dst error:nil];
	NSError *err = nil;
	if (![fm copyItemAtPath:src toPath:dst error:&err]) {
		fprintf(stderr, "InferNode: root copy failed (%s); falling back to read-only bundle\n",
				err.localizedDescription.UTF8String);
		return strdup([src fileSystemRepresentation]);
	}
	nftw([dst fileSystemRepresentation], mk_writable, 32, FTW_PHYS);
	return strdup([dst fileSystemRepresentation]);
}

int
main(int argc, char *argv[])
{
	(void)argc;
	(void)argv;
	@autoreleasepool {
		/* Don't let the umask strip group/other bits off dirs the boot
		 * creates: devfs-posix mkdir's at the requested mode minus umask,
		 * so umask 022 turns /n (DMDIR|0777) into 0755, and services
		 * running as a non-owner Inferno user then can't create /n/ui.
		 * umask 0 keeps created dirs fully writable. */
		umask(0);

		char *root = prepare_writable_root();
		/* chdir + "-r ." dodges emu's MAXROOT(140) rootdir overflow on
		 * the long container path; devfs-posix resolves relative to CWD. */
		if (chdir(root) != 0)
			fprintf(stderr, "InferNode: chdir(%s) failed\n", root);

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

		fprintf(stderr, "InferNode GUI: emu_run booting lucifer (-c0), root=%s\n", root);
		return emu_run(ac, av);
	}
}
