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
/* Match Bionic's actual signature (ssize_t return) so this extern is
 * identical to the one in <sys/random.h> when __ANDROID_API__ >= 28
 * (no redeclaration conflict), and still satisfies the call site below
 * when the header guard hides the libc declaration on older API
 * targets. */
extern ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);
#endif
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#endif

/*
 * Fill a buffer with cryptographically secure random bytes.
 *
 * prngtry() reports failure to the caller; prng() treats failure as
 * fatal.  Code that can degrade or report an error (a /dev entry
 * serving a whole VM, say) must use prngtry(): aborting there turns a
 * degraded-entropy condition into a crash for every hosted process.
 * Code that would otherwise use weak key material must use prng().
 *
 * Returns 0 on success, -1 if the buffer could not be completely
 * filled from a secure source.  A partial buffer is never returned as
 * success.
 */
int
prngtry(uchar *p, int n)
{
	if(n <= 0)
		return 0;
#if defined(__APPLE__)
	arc4random_buf(p, n);
	return 0;
#elif defined(_WIN32)
	if(BCryptGenRandom(NULL, p, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG) != 0)
		return -1;
	return 0;
#elif defined(__linux__)
	while(n > 0) {
		ssize_t r = getrandom(p, n, 0);
		if(r < 0) {
			if(errno == EINTR)
				continue;
			/* fallback to /dev/urandom; must fill completely */
			int fd = open("/dev/urandom", 0);
			if(fd >= 0) {
				while(n > 0) {
					ssize_t rr = read(fd, p, n);
					if(rr < 0 && errno == EINTR)
						continue;
					if(rr <= 0)
						break;
					p += rr;
					n -= rr;
				}
				close(fd);
			}
			return n > 0 ? -1 : 0;
		}
		p += r;
		n -= r;
	}
	return 0;
#else
	int fd;
	fd = open("/dev/urandom", 0);
	if(fd >= 0) {
		while(n > 0) {
			ssize_t r = read(fd, p, n);
			if(r < 0 && errno == EINTR)
				continue;
			if(r <= 0)
				break;
			p += r;
			n -= r;
		}
		close(fd);
	}
	return n > 0 ? -1 : 0;
#endif
}

void
prng(uchar *p, int n)
{
	if(prngtry(p, n) < 0) {
		/* no secure random source — abort rather than proceed with
		 * unfilled or predictable key material */
		fprint(2, "prng: no secure random source available, aborting\n");
		abort();
	}
}
