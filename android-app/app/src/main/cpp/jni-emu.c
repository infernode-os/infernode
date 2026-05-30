/*
 * jni-emu.c — JNI bridge between Java (io.infernode.Emu) and the
 * InferNode emulator entry point.
 *
 * Phase 2a (INFR-NNN): real interactive shell.
 *   - capture_stdio replaces the previous capture_stdio: it now wires
 *     fd 0, 1, and 2. fd 0 is the read end of a stdin pipe owned by
 *     this C side; Java writes to it via writeStdin(). fd 1/2 are
 *     dup2'd to a stdout pipe whose read end is consumed by a reader
 *     thread that fans output to logcat AND a Java OutputListener.
 *   - The reader thread attaches to the JVM so it can call back into
 *     Kotlin. AttachCurrentThread is required because the thread
 *     wasn't created by the JVM.
 *
 * Phase 1d (INFR-111) earlier landed:
 *   - Detached pthread for emu_run so JVM-attached thread can return.
 *   - Stdio capture to logcat under tag "InferNode".
 *   - Atomic guard against multiple Emu.run calls per process.
 *
 * Single-instance constraint: emu's globals are process-scoped. A
 * second Emu.run is rejected.
 */

#include <jni.h>
#include <android/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>
#include <stdatomic.h>
#include <errno.h>

#define TAG "InferNode"

extern int emu_run(int argc, char **argv);

/*
 * JNI globals captured at load time / when a listener registers.
 * Access to g_listener / g_onLine_mid is guarded by g_listener_lock
 * because the stdio reader pthread and Java callers both touch them.
 */
/* Owned by emu/Android/phonebridge.c — that translation unit links into
 * both the headless o.emu and libemu.so. We just read/write it from
 * JNI_OnLoad (INFR-201). */
extern JavaVM *g_vm;
static jobject g_listener;          /* global ref */
static jmethodID g_onLine_mid;
static pthread_mutex_t g_listener_lock = PTHREAD_MUTEX_INITIALIZER;

/*
 * Write end of the stdin pipe — fd 0 is the read end (dup2'd at
 * capture time). Java's writeStdin writes here; emu's readkbd kproc
 * reads from fd 0 and pushes to kbdq.
 */
static int g_stdin_write_fd = -1;

/*
 * Reader thread for the stdout/stderr pipe. Splits on '\n' so each
 * line becomes one logcat entry / one OutputListener call. emu's
 * print() output reaches both surfaces.
 */
static void
deliver_line(JNIEnv *env, const char *line)
{
	if (line[0] != '\0')
		__android_log_write(ANDROID_LOG_INFO, TAG, line);

	pthread_mutex_lock(&g_listener_lock);
	jobject listener = g_listener;
	jmethodID mid = g_onLine_mid;
	pthread_mutex_unlock(&g_listener_lock);

	if (env != NULL && listener != NULL && mid != NULL) {
		jstring jline = (*env)->NewStringUTF(env, line);
		if (jline != NULL) {
			(*env)->CallVoidMethod(env, listener, mid, jline);
			(*env)->DeleteLocalRef(env, jline);
		}
		if ((*env)->ExceptionCheck(env))
			(*env)->ExceptionClear(env);
	}
}

static void *
stdio_reader(void *arg)
{
	int fd = (int)(intptr_t)arg;
	char buf[1024];
	ssize_t n;
	JNIEnv *env = NULL;

	pthread_setname_np(pthread_self(), "emu-stdio");

	/* Attach this pthread to the JVM so we can call into Kotlin. */
	if (g_vm != NULL &&
	    (*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) {
		env = NULL;
		__android_log_write(ANDROID_LOG_WARN, TAG,
			"stdio reader: AttachCurrentThread failed; "
			"output will reach logcat only, not the Activity");
	}

	while ((n = read(fd, buf, sizeof(buf) - 1)) > 0) {
		buf[n] = '\0';
		char *p = buf;
		while (*p != '\0') {
			char *eol = strchr(p, '\n');
			if (eol != NULL)
				*eol = '\0';
			deliver_line(env, p);
			if (eol == NULL)
				break;
			p = eol + 1;
		}
	}

	if (env != NULL && g_vm != NULL)
		(*g_vm)->DetachCurrentThread(g_vm);
	return NULL;
}

static void
capture_stdio(void)
{
	int sp[2], op[2];
	pthread_t reader;

	/*
	 * Stdin: read end goes to fd 0; emu's readkbd will read from
	 * here. Java owns the write end via g_stdin_write_fd.
	 */
	if (pipe(sp) != 0) {
		__android_log_write(ANDROID_LOG_WARN, TAG,
			"stdin pipe() failed; emu shell will read /dev/null");
	} else {
		dup2(sp[0], STDIN_FILENO);
		close(sp[0]);
		g_stdin_write_fd = sp[1];
	}

	/*
	 * Stdout + stderr: both dup2'd to the same pipe write end so
	 * one reader thread sees all emu output in order.
	 */
	if (pipe(op) != 0) {
		__android_log_write(ANDROID_LOG_WARN, TAG,
			"stdout pipe() failed; emu output discarded");
		return;
	}
	dup2(op[1], STDOUT_FILENO);
	dup2(op[1], STDERR_FILENO);
	close(op[1]);

	setvbuf(stdout, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IOLBF, 0);

	if (pthread_create(&reader, NULL, stdio_reader,
	    (void *)(intptr_t)op[0]) == 0)
		pthread_detach(reader);
}

/* ─── emu lifecycle ──────────────────────────────────────────── */

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

	int rc = emu_run(a->argc, a->argv);

	/* Headless emu_run is not supposed to return; if it does, free
	 * the heap argv we own and report the surprise. */
	__android_log_print(ANDROID_LOG_INFO, TAG,
		"emu_run returned %d (unexpected for headless)", rc);
	for (i = 0; i < a->argc; i++)
		free(a->argv[i]);
	free(a->argv);
	free(a);
	return NULL;
}

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

/* ─── stdin write ────────────────────────────────────────────── */

/*
 * Write the given bytes to emu's stdin pipe. Returns the number of
 * bytes written (>= 0) or -1 on error. Java is expected to append
 * '\n' itself for line-oriented input.
 */
JNIEXPORT jint JNICALL
Java_io_infernode_Emu_writeStdin(JNIEnv *env, jclass cls, jstring jdata)
{
	(void)cls;

	if (g_stdin_write_fd < 0)
		return -1;

	const char *data = (*env)->GetStringUTFChars(env, jdata, NULL);
	if (data == NULL)
		return -1;
	jsize len = (*env)->GetStringUTFLength(env, jdata);

	ssize_t total = 0;
	while (total < len) {
		ssize_t w = write(g_stdin_write_fd, data + total, len - total);
		if (w < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		total += w;
	}

	(*env)->ReleaseStringUTFChars(env, jdata, data);
	return (jint)total;
}

/* ─── output listener ────────────────────────────────────────── */

JNIEXPORT void JNICALL
Java_io_infernode_Emu_setOutputListener(JNIEnv *env, jclass cls, jobject listener)
{
	(void)cls;

	pthread_mutex_lock(&g_listener_lock);

	if (g_listener != NULL) {
		(*env)->DeleteGlobalRef(env, g_listener);
		g_listener = NULL;
	}
	g_onLine_mid = NULL;

	if (listener != NULL) {
		g_listener = (*env)->NewGlobalRef(env, listener);
		if (g_listener != NULL) {
			jclass lcls = (*env)->GetObjectClass(env, g_listener);
			g_onLine_mid = (*env)->GetMethodID(env, lcls,
				"onLine", "(Ljava/lang/String;)V");
			if ((*env)->ExceptionCheck(env))
				(*env)->ExceptionClear(env);
		}
	}

	pthread_mutex_unlock(&g_listener_lock);
}

/* ─── load entry ─────────────────────────────────────────────── */

JNIEXPORT jint JNICALL
JNI_OnLoad(JavaVM *vm, void *reserved)
{
	(void)reserved;
	g_vm = vm;
	capture_stdio();
	__android_log_write(ANDROID_LOG_INFO, TAG,
		"libemu.so JNI_OnLoad — stdin/stdout routed");
	return JNI_VERSION_1_6;
}

#ifdef GUI_SDL3
/*
 * SDL_main — entry point invoked by SDL3 on the SDL thread, after
 * SDLActivity has set up the surface, audio devices, and IME plumbing.
 *
 * Phase 2b.1 wiring: when InfernodeSDLActivity launches, SDL3's Java
 * layer loads libSDL3.so + libemu.so, creates the SurfaceView, and
 * resolves this symbol via dlsym(libemu.so, "SDL_main"). The argv it
 * passes comes from InfernodeSDLActivity.getArguments() — the same
 * shape as the headless boot, minus argv[0].
 *
 * We just hand control to emu_run. Unlike the JNI path
 * (Java_io_infernode_Emu_run), there is no separate worker pthread
 * here — SDL3 owns this thread and expects SDL_main to either return
 * (clean shutdown) or block forever (typical for emulators). emu's
 * `for(;;) ospause();` is the latter; the thread becomes the emu
 * main kproc, which is fine because no JVM-thread invariants apply
 * (this thread was created by SDL3, not the JVM).
 */
int
SDL_main(int argc, char *argv[])
{
	__android_log_print(ANDROID_LOG_INFO, TAG,
		"SDL_main starting (argc=%d)", argc);
	return emu_run(argc, argv);
}
#endif
