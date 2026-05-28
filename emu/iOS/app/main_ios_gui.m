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
#include <dirent.h>
#include <errno.h>
#include <string.h>
#include <limits.h>

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
 * POSIX-level recursive remove (rm -rf), used to dislodge legacy
 * devicectl-pushed dirs in dst/lib/. NSFileManager refuses to remove
 * those (Apple sandbox marks devicectl-created paths as
 * app-write-restricted even though the app's runtime uid owns them),
 * but the raw unlink/rmdir calls hit the BSD perm checks and usually
 * succeed because we are in fact the owner.
 */
static int
posix_rm_rf(const char *path)
{
	struct stat sb;
	if (lstat(path, &sb) != 0)
		return 0;
	if (S_ISDIR(sb.st_mode)) {
		DIR *d = opendir(path);
		if (d != NULL) {
			struct dirent *ent;
			char child[PATH_MAX];
			while ((ent = readdir(d)) != NULL) {
				if (strcmp(ent->d_name, ".") == 0 ||
				    strcmp(ent->d_name, "..") == 0)
					continue;
				snprintf(child, sizeof(child), "%s/%s",
					path, ent->d_name);
				posix_rm_rf(child);
			}
			closedir(d);
		}
		return rmdir(path);
	}
	return unlink(path);
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
	BOOL srcIsDir = NO;
	if (![fm fileExistsAtPath:src isDirectory:&srcIsDir])
		return;
	if (!srcIsDir) {
		/* file: replace in place — remove first so copy doesn't error */
		[fm removeItemAtPath:dst error:nil];
		NSError *cerr = nil;
		if (![fm copyItemAtPath:src toPath:dst error:&cerr])
			fprintf(stderr, "deep_merge: copy %s -> %s failed: %s\n",
				rel.UTF8String, dst.fileSystemRepresentation,
				cerr.localizedDescription.UTF8String);
		return;
	}
	/* dir: ensure dst dir exists, then recurse */
	BOOL dstIsDir = NO;
	if (![fm fileExistsAtPath:dst isDirectory:&dstIsDir]) {
		NSError *derr = nil;
		if (![fm createDirectoryAtPath:dst withIntermediateDirectories:YES
				attributes:nil error:&derr])
			fprintf(stderr, "deep_merge: mkdir %s failed: %s\n",
				rel.UTF8String, derr.localizedDescription.UTF8String);
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
 * Overlay `src` (operator-pushed config at Documents/inferno-overlay/)
 * onto `dst` (the app-owned writable root). For each leaf in src, read
 * via NSData (works even on devicectl-pushed app-write-restricted
 * sources because we only need READ) and write into dst via NSData
 * writeToFile (always succeeds — dst was wiped + recreated by us).
 * Skip leaves we can't read (logged once); never recurse into preserved
 * directories — overlay is whatever the operator chose to push.
 */
static void
overlay_walk(NSFileManager *fm, NSString *src, NSString *dst)
{
	BOOL srcIsDir = NO;
	if (![fm fileExistsAtPath:src isDirectory:&srcIsDir])
		return;
	if (!srcIsDir) {
		NSData *data = [NSData dataWithContentsOfFile:src];
		if (data == nil) {
			fprintf(stderr, "overlay: cannot read %s\n",
				src.fileSystemRepresentation);
			return;
		}
		NSString *parent = [dst stringByDeletingLastPathComponent];
		[fm createDirectoryAtPath:parent withIntermediateDirectories:YES
				attributes:nil error:nil];
		[fm removeItemAtPath:dst error:nil];
		if (![data writeToFile:dst atomically:YES])
			fprintf(stderr, "overlay: cannot write %s\n",
				dst.fileSystemRepresentation);
		return;
	}
	[fm createDirectoryAtPath:dst withIntermediateDirectories:YES
			attributes:nil error:nil];
	NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:src error:nil];
	for (NSString *child in children)
		overlay_walk(fm,
			[src stringByAppendingPathComponent:child],
			[dst stringByAppendingPathComponent:child]);
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
	 * First launch or a new build: refresh from the bundle.
	 *
	 * Two iOS-specific complications drive the shape below:
	 *
	 *  1. Anything pushed by `devicectl device copy to` arrives marked
	 *     app-write-restricted: even though the app's runtime uid owns
	 *     the file, NSFileManager refuses every removeItemAtPath,
	 *     createDirectoryAtPath, and copyItemAtPath that touches the
	 *     containing dir. Concrete symptom: if creds were pushed into
	 *     Caches/inferno/lib/keyring/, deep_merge cannot add
	 *     lib/lucifer/ next to them and boot dies. POSIX
	 *     unlink/rmdir bypass that block (BSD perm check sees us as
	 *     owner) — sledgehammer the whole dst tree via posix_rm_rf
	 *     before deep_merge so we start from a clean, app-owned
	 *     hierarchy.
	 *  2. Wiping dst also wipes any user-pushed config. The correct
	 *     push target for operators is Documents/inferno-overlay/...
	 *     (Documents is app-writable end-to-end and survives Caches
	 *     refresh): mirror lib/keyring/serve-llm at
	 *     Documents/inferno-overlay/lib/keyring/serve-llm. After
	 *     deep_merge, we overlay anything in Documents/inferno-overlay/
	 *     onto Caches/inferno/ — operator-pushed leaf files replace
	 *     bundle placeholders (so lib/ndb/llm = mode=remote wins over
	 *     the bundle's mode=local default).
	 */
	if ([fm fileExistsAtPath:dst]) {
		fprintf(stderr, "InferNode: refreshing writable root (posix_rm_rf + deep_merge)\n");
		if (posix_rm_rf([dst fileSystemRepresentation]) != 0)
			fprintf(stderr, "InferNode: posix_rm_rf(%s) had errors: %s\n",
				dst.fileSystemRepresentation, strerror(errno));
	}
	[fm createDirectoryAtPath:dst withIntermediateDirectories:YES
			attributes:nil error:nil];
	deep_merge(fm, src, dst, @"");

	/* Overlay Documents/inferno-overlay/ (operator-pushed config) onto
	 * dst. NSData read+write here, not copyItemAtPath: the overlay
	 * source may itself be app-write-restricted (operator pushed via
	 * devicectl), but we can still READ it; the WRITE goes into the
	 * app-owned deep_merged tree so it always succeeds. */
	NSString *overlay = [[NSSearchPathForDirectoriesInDomains(
			NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
			stringByAppendingPathComponent:@"inferno-overlay"];
	if ([fm fileExistsAtPath:overlay]) {
		fprintf(stderr, "InferNode: overlaying %s -> %s\n",
			overlay.fileSystemRepresentation, dst.fileSystemRepresentation);
		overlay_walk(fm, overlay, dst);
	}

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
