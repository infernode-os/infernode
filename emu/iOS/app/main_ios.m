/*
 * InferNode iOS app entry — hellaphone Phase 2b, B0 (headless shell).
 *
 * The design's "thin Xcode wrapper": the app provides the UIKit entry
 * point and links libemu.a (emu/port + emu/iOS), rather than emu owning
 * main(). Headless emu boots interpreter-only (-c0 — Apple's W^X forbids
 * the JIT) against an Inferno root bundled in the .app, and runs the
 * Limbo test runner to prove the VM/9P/Veltro stack works inside a real
 * iOS app process (not just `simctl spawn` of a bare binary, as Phase A
 * did).
 *
 * Threading: headless emu_run()'s libinit() never returns (worker
 * kprocs take over), but the main thread must run the UIKit run loop.
 * So emu_run() runs on a detached pthread; the main thread stays in
 * UIApplicationMain. (Phase B1 swaps the headless boot for the SDL3
 * GUI, where the main thread runs the SDL/Metal loop instead.)
 *
 * Output goes to stdout/stderr; capture it with `simctl launch --console`.
 */

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* libemu.a, emu/port/main.c — built with -DEMU_NO_MAIN so it exports
 * emu_run() but not main(). */
extern int emu_run(int argc, char *argv[]);

static char *g_root;            /* bundled Inferno root, strdup'd */

static void *
emu_thread(void *arg)
{
	(void)arg;
	/* The bundle root path (~180 chars) overflows emu's rootdir buffer
	 * (MAXROOT = 5*KNAMELEN = 140), so chdir there and pass "-r ." — a
	 * 1-char root that devfs-posix resolves relative to the CWD. emu
	 * never chdir()s afterward, so the CWD stays put. */
	if (chdir(g_root) != 0)
		fprintf(stderr, "InferNode: chdir(%s) failed: %s\n",
				g_root, strerror(errno));

	/* argv mirrors the Phase A simctl-spawn smoke test:
	 *   emu -c0 -r . /tests/hello_test.dis    (CWD = bundle root)
	 * -c0 is the iOS contract (no JIT). */
	char *argv[] = {
		"InferNode",
		"-c0",
		"-r", ".",
		"/tests/hello_test.dis",
		NULL
	};
	int argc = (int)(sizeof(argv) / sizeof(argv[0])) - 1;

	fprintf(stderr, "InferNode: emu_run(-c0 -r . /tests/hello_test.dis), root=%s\n", g_root);
	emu_run(argc, argv);
	/* headless emu_run() does not return; note it if it ever does. */
	fprintf(stderr, "InferNode: emu_run returned\n");
	return NULL;
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate
- (BOOL)application:(UIApplication *)application
		didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	/* A minimal screen so the app isn't a black void; the real work is
	 * headless and shows up in the console. */
	self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
	UIViewController *vc = [[UIViewController alloc] init];
	vc.view.backgroundColor = [UIColor blackColor];
	UILabel *label = [[UILabel alloc] initWithFrame:vc.view.bounds];
	label.text = @"InferNode\n(headless emu -c0)\nsee Xcode/simctl console";
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.textColor = [UIColor greenColor];
	label.font = [UIFont fontWithName:@"Menlo" size:16] ?: [UIFont systemFontOfSize:16];
	label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[vc.view addSubview:label];
	self.window.rootViewController = vc;
	[self.window makeKeyAndVisible];

	/* Inferno root is bundled at <App>.app/root (resourcePath is the
	 * .app itself on iOS). */
	NSString *root = [[[NSBundle mainBundle] resourcePath]
			stringByAppendingPathComponent:@"root"];
	g_root = strdup([root fileSystemRepresentation]);

	pthread_t t;
	if (pthread_create(&t, NULL, emu_thread, NULL) != 0) {
		fprintf(stderr, "InferNode: pthread_create failed\n");
		label.text = @"InferNode: failed to start emu";
	} else {
		pthread_detach(t);
	}
	return YES;
}
@end

int
main(int argc, char *argv[])
{
	@autoreleasepool {
		return UIApplicationMain(argc, argv, nil,
				NSStringFromClass([AppDelegate class]));
	}
}
