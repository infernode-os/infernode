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
 * Operator-pushed configuration that must survive an app rebuild. The
 * bundle either ships a placeholder for these (lib/ndb/llm = mode=local)
 * or nothing at all (lib/keyring/ is empty in the bundle); a deep_merge
 * that blindly clobbers from the bundle wipes the user's remote-LLM
 * configuration and keyring credentials on every rebuild, sending the
 * device back to mode=local with no auth. Skip them.
 *
 * `rel` is the dst path relative to the writable inferno root.
 */
static BOOL
is_preserved_path(NSString *rel)
{
	return [rel isEqualToString:@"lib/ndb/llm"]
		|| [rel isEqualToString:@"lib/keyring"]
		|| [rel hasPrefix:@"lib/keyring/"];
}

/*
 * Recursive merge of `src` into `dst`. For each leaf file in src, replace
 * the corresponding file in dst (best-effort — leave it alone if remove
 * fails, which happens to devicectl-pushed files whose perms the runtime
 * uid can't override on iOS). Directories are entered, not blindly
 * overwritten — that's the bug the earlier flat child-by-child merge had:
 * a stale top-level dir (e.g. /lib with only keyring/ and ndb/ in it) was
 * "kept" as a unit and the bundle's full lib/ (with lucifer/, sh/, …)
 * never got merged in. Result: boot fails with "/lib/lucifer does not
 * exist" because lib/lucifer/ was never copied. Recurse.
 *
 * `rel` is the dst path relative to the writable inferno root; the
 * top-level call passes @"". Used only for is_preserved_path checks.
 */
static void
deep_merge(NSFileManager *fm, NSString *src, NSString *dst, NSString *rel)
{
	if ([rel length] > 0 && is_preserved_path(rel))
		return;
	BOOL srcIsDir = NO;
	if (![fm fileExistsAtPath:src isDirectory:&srcIsDir])
		return;
	if (!srcIsDir) {
		/* file: replace in place — remove first so copy doesn't error */
		[fm removeItemAtPath:dst error:nil];
		[fm copyItemAtPath:src toPath:dst error:nil];
		return;
	}
	/* dir: ensure dst dir exists, then recurse */
	BOOL dstIsDir = NO;
	if (![fm fileExistsAtPath:dst isDirectory:&dstIsDir]) {
		[fm createDirectoryAtPath:dst withIntermediateDirectories:YES
				attributes:nil error:nil];
	} else if (!dstIsDir) {
		/* dst is a regular file where src is a dir — try to replace */
		[fm removeItemAtPath:dst error:nil];
		[fm createDirectoryAtPath:dst withIntermediateDirectories:YES
				attributes:nil error:nil];
	}
	NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:src error:nil];
	for (NSString *child in children) {
		NSString *crel = ([rel length] > 0)
			? [rel stringByAppendingPathComponent:child]
			: child;
		deep_merge(fm,
			[src stringByAppendingPathComponent:child],
			[dst stringByAppendingPathComponent:child],
			crel);
	}
}

/*
 * The Inferno root is bundled read-only in the .app, but the boot (and the
 * user, via Settings) must write to it (/lib/ndb/llm, /lib/lucifer/theme,
 * keyring, /n, /tmp, ...). So run emu from a writable copy in the app's
 * Caches container.
 *
 * Persistence vs. dev-rebuild: we must NOT re-copy on every launch, or
 * saved settings are wiped each restart — but we MUST refresh when a new
 * build is installed, or stale dis would run. Resolve both by keying the
 * copy on the app executable's mtime (changes on every rebuild): same
 * build → keep the existing writable tree (settings survive a relaunch);
 * new build (or first launch) → fresh copy from the bundle. Returns a
 * strdup'd path.
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
	NSString *marker = [dst stringByAppendingPathComponent:@".bundle-build"];

	/* Build identity = executable mtime (rewritten by each app build). */
	NSString *want = @"0";
	struct stat est;
	if (stat([[[NSBundle mainBundle] executablePath] fileSystemRepresentation], &est) == 0)
		want = [NSString stringWithFormat:@"%llu", (unsigned long long)est.st_mtime];

	if ([fm fileExistsAtPath:dst]) {
		NSString *got = [NSString stringWithContentsOfFile:marker
				encoding:NSUTF8StringEncoding error:nil];
		if (got != nil && [got isEqualToString:want]) {
			/*
			 * Marker matches — but only honour PRESERVE if the writable
			 * root is actually complete. A previous broken merge could
			 * have stamped the marker on a half-populated tree (e.g.
			 * /lib with just keyring/+ndb/ from pushed creds, missing
			 * /lib/lucifer/). PRESERVE would then short-circuit
			 * deep_merge and the boot dies with `sh: cannot open
			 * /lib/lucifer/boot-mobile.sh`. Canary: boot-mobile.sh
			 * itself. If absent, distrust the marker and re-merge.
			 */
			NSString *canary = [dst stringByAppendingPathComponent:
					@"lib/lucifer/boot-mobile.sh"];
			if ([fm fileExistsAtPath:canary]) {
				/* Same build, just a relaunch — keep writable state so
				 * the user's settings persist. */
				return strdup([dst fileSystemRepresentation]);
			}
			fprintf(stderr, "InferNode: marker matched but %s missing — re-merging\n",
					canary.fileSystemRepresentation);
		}
	}

	/*
	 * First launch or a new build: refresh from the bundle. Writable
	 * state from an OLDER build is intentionally discarded.
	 *
	 * Always go via deep_merge — never wholesale [fm copyItemAtPath:src
	 * toPath:dst]. Two reasons:
	 *
	 *  1. The wholesale copy needs dst gone first, so it would have to
	 *     removeItemAtPath:dst. On iOS that fails because devicectl-
	 *     pushed files (lib/keyring/serve-llm, lib/ndb/llm) have perms
	 *     the runtime uid can't override — leaving us bailing back to
	 *     the read-only bundle (no /tmp, no /usr, mode=local).
	 *  2. Even on the sim where the wholesale copy succeeds, it wipes
	 *     the operator-pushed config every rebuild — so the bundle's
	 *     placeholder ndb/llm (mode=local) and empty keyring overwrite
	 *     what the operator pushed. deep_merge's preserve list keeps
	 *     them intact.
	 *
	 * One code path on both targets: deep_merge from bundle, leave
	 * preserved paths alone, make everything writable, stamp marker.
	 */
	if ([fm fileExistsAtPath:dst]) {
		fprintf(stderr, "InferNode: refreshing writable root (deep_merge from bundle)\n");
	} else {
		[fm createDirectoryAtPath:dst withIntermediateDirectories:YES
				attributes:nil error:nil];
		fprintf(stderr, "InferNode: first-launch populate (deep_merge from bundle)\n");
	}
	deep_merge(fm, src, dst, @"");
	nftw([dst fileSystemRepresentation], mk_writable, 32, FTW_PHYS);
	[want writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
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
