/*
 * jni-emu.c — JNI bridge between Java (io.infernode.Emu) and the
 * InferNode emulator entry point.
 *
 * Phase 1d (INFR-111) refactor. Previously this file just marshalled
 * argv and called emu_run(...) on the JVM-attached JNI thread. That
 * crashed the process within ~22 ms of libemu.so loading, because
 * emu's headless boot path ends in `for(;;) ospause();` and
 * ospause() does pthread_exit(0). pthread_exit on a JNI-attached
 * thread is undefined; the zygote saw the thread vanish and SIGKILLed
 * the process.
 *
 * Two changes fix it:
 *
 * 1. emu_run runs on its own detached pthread, not on the JVM caller.
 *    The JVM caller returns to Java immediately. emu's eventual
 *    pthread_exit lands on a thread the JVM doesn't know about, so
 *    the runtime never sees a stray death and the process keeps
 *    running indefinitely.
 *
 * 2. stdio (fd 1 and fd 2) is redirected to a pipe at JNI_OnLoad,
 *    and a reader thread pushes lines to __android_log_write so
 *    emu's print()/fprint() output shows up in logcat under the
 *    "InferNode" tag. Without this, every diagnostic emu emits goes
 *    to /dev/null and the boot is invisible.
 *
 * Single-instance constraint: emu's globals (rootdir, eve, libinit
 * state, etc.) are process-scoped. A static guard ensures emu_run is
 * spawned at most once per process — repeat clicks on the boot
 * button are no-ops.
 */

#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdatomic.h>

#define TAG "InferNode"

extern int emu_run(int argc, char **argv);

/*
 * Stdio capture: pipe fd1/fd2 into a reader that flushes line-by-line
 * to logcat. setvbuf on stdout/stderr to line-buffered so prints
 * surface promptly even before any newline.
 *
 * Buffer size 1024 matches emu's internal print buffer in
 * emu/port/main.c iprint(). Long lines get split across reads, which
 * logcat shows as separate entries — acceptable for a debug surface.
 */
static void *
stdio_reader(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char buf[1024];
	ssize_t n, lineLen;
	char *p, *eol;

	pthread_setname_np(pthread_self(), "emu-stdio");

	while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = '\0';
		/* Split on newlines so each log entry is one line. */
		p = buf;
		while (*p != '\0') {
			eol = strchr(p, '\n');
			if (eol != NULL) {
				*eol = '\0';
				lineLen = eol - p;
			} else {
				lineLen = (ssize_t)strlen(p);
			}
			if (lineLen > 0)
				__android_log_write(ANDROID_LOG_INFO, TAG, p);
			if (eol == NULL)
				break;
			p = eol + 1;
		}
	}
	return NULL;
}

static void
capture_stdio(void)
{
	int p[2];
	pthread_t reader;

	if (pipe(p) != 0) {
		__android_log_write(ANDROID_LOG_WARN, TAG,
			"stdio pipe() failed; emu output will not reach logcat");
		return;
	}
	dup2(p[1], STDOUT_FILENO);
	dup2(p[1], STDERR_FILENO);
	close(p[1]);

	setvbuf(stdout, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IOLBF, 0);

	if (pthread_create(&reader, NULL, stdio_reader,
	    (void *)(intptr_t)p[0]) == 0)
		pthread_detach(reader);
}

/*
 * Worker thread that owns emu's lifetime. Takes ownership of the
 * heap-allocated argv built by Java_io_infernode_Emu_run; frees it
 * after emu_run returns (which in headless mode means: never).
 */
struct emu_args {
	int argc;
	char **argv;
};

static void *
emu_thread(void *arg)
{
	struct emu_args *a = (struct emu_args *)arg;
	int i;

	pthread_setname_np(pthread_self(), "emu-main");
	__android_log_print(ANDROID_LOG_INFO, TAG,
		"emu_run starting (argc=%d)", a->argc);

	/* In headless mode emu_run never returns — emuinit() does
	 * for(;;) ospause() and ospause() pthread_exit()s this very
	 * thread. The free() below only runs if the build path ever
	 * grows a clean shutdown. */
	int rc = emu_run(a->argc, a->argv);

	__android_log_print(ANDROID_LOG_INFO, TAG,
		"emu_run returned %d (unexpected for headless)", rc);

	for (i = 0; i < a->argc; i++)
		free(a->argv[i]);
	free(a->argv);
	free(a);
	return NULL;
}

/*
 * Guard against multiple Emu.run calls. emu can only boot once per
 * process; a second call would race on globals and almost certainly
 * crash. Using an atomic flag rather than pthread_once because we
 * want to *report* re-entry via a logcat line, not silently swallow it.
 */
static atomic_int emu_launched = ATOMIC_VAR_INIT(0);

JNIEXPORT jint JNICALL
Java_io_infernode_Emu_run(JNIEnv *env, jobject thiz, jobjectArray jargv)
{
	(void)thiz;

	int expected = 0;
	if (!atomic_compare_exchange_strong(&emu_launched, &expected, 1)) {
		__android_log_write(ANDROID_LOG_WARN, TAG,
			"Emu.run called more than once — ignoring");
		return -1;
	}

	const jsize n = (*env)->GetArrayLength(env, jargv);

	struct emu_args *a = (struct emu_args *)calloc(1, sizeof(*a));
	if (a == NULL)
		return -1;

	/* argv layout: [0] = "emu", [1..n] = caller args, [n+1] = NULL. */
	a->argv = (char **)calloc((size_t)n + 2, sizeof(char *));
	if (a->argv == NULL) {
		free(a);
		return -1;
	}
	a->argv[0] = strdup("emu");
	a->argc = 1;

	for (int i = 0; i < n; i++) {
		jstring s = (jstring)(*env)->GetObjectArrayElement(env, jargv, i);
		const char *cs = (*env)->GetStringUTFChars(env, s, NULL);
		a->argv[a->argc++] = strdup(cs);
		(*env)->ReleaseStringUTFChars(env, s, cs);
		(*env)->DeleteLocalRef(env, s);
	}

	pthread_t t;
	if (pthread_create(&t, NULL, emu_thread, a) != 0) {
		__android_log_write(ANDROID_LOG_ERROR, TAG,
			"pthread_create for emu-main failed");
		for (int i = 0; i < a->argc; i++)
			free(a->argv[i]);
		free(a->argv);
		free(a);
		return -1;
	}
	pthread_detach(t);

	return 0;
}

/*
 * JNI_OnLoad runs once when System.loadLibrary("emu") completes.
 * Wire up stdio capture here so even emu's earliest startup prints
 * (before emu_thread takes off) reach logcat — useful when the
 * crash is in argument parsing or the env scan.
 */
JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *reserved)
{
	(void)vm;
	(void)reserved;
	capture_stdio();
	__android_log_write(ANDROID_LOG_INFO, TAG,
		"libemu.so JNI_OnLoad — stdio routed to logcat");
	return JNI_VERSION_1_6;
}
