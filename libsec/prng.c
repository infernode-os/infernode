#include "os.h"
#include <mp.h>
#include <libsec.h>
#if defined(__linux__)
#include <sys/random.h>
#if defined(__BIONIC__)
/*
 * Bionic's <sys/random.h> hides the getrandom() declaration behind
 * __ANDROID_API__ >= 28. Termux's clang may target a lower minSdk
 * (16/24/etc.) even on a current device, so the prototype stays
 * invisible and -Werror=implicit-function-declaration kills the build.
 *
 * The symbol is in libc.so on every Android Termux supports
 * (the Linux getrandom syscall has been around since Android 6 / API
 * 23, and Bionic's wrapper has been exported since 28), so it is safe
 * to re-declare here. No effect on non-Bionic platforms.
 */
extern int getrandom(void *buf, size_t buflen, unsigned int flags);
#endif
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#endif

//
//  fill a buffer with cryptographically secure random bytes
//
void
prng(uchar *p, int n)
{
#if defined(__APPLE__)
	arc4random_buf(p, n);
#elif defined(_WIN32)
	if(BCryptGenRandom(NULL, p, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0) {
		fprint(2, "prng: BCryptGenRandom failed, aborting\n");
		abort();
	}
#elif defined(__linux__)
	while(n > 0) {
		ssize_t r = getrandom(p, n, 0);
		if(r < 0) {
			if(errno == EINTR)
				continue;
			/* fallback to /dev/urandom */
			int fd = open("/dev/urandom", 0);
			if(fd >= 0) {
				if(read(fd, p, n)){/*nothing*/}
				close(fd);
			}
			return;
		}
		p += r;
		n -= r;
	}
#else
	int fd;
	fd = open("/dev/urandom", 0);
	if(fd >= 0) {
		if(read(fd, p, n)){/*nothing*/}
		close(fd);
	} else {
		/* no secure random source available — abort rather than
		 * silently falling back to the insecure C rand() */
		fprint(2, "prng: no secure random source available "
			"(/dev/urandom failed), aborting\n");
		abort();
	}
#endif
}
