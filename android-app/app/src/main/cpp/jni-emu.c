/*
 * jni-emu.c — JNI bridge between Java (io.infernode.Emu) and the
 * InferNode emulator entry point.
 *
 * Phase 1c scaffold. This file lives under android-app/app/src/main/cpp/
 * but is NOT compiled by Gradle in the v1 packaging strategy — the
 * libemu.so it would produce instead comes from the existing Inferno
 * mkfile chain via a `build-android-apk.sh` driver (Phase 1c follow-up).
 *
 * That follow-up needs to:
 *
 *   1. Refactor emu/port/main.c so the body of main() becomes a
 *      callable `int emu_run(int argc, char **argv)`. The existing
 *      main() stays as a 3-line shim that just calls emu_run for the
 *      `adb shell /data/local/tmp/o.emu` path.
 *
 *   2. Add a build flag to emu/Android/mkfile-g that produces both
 *      o.emu (PIE executable, current behaviour) and libemu.so
 *      (-shared, exporting Java_io_infernode_Emu_run + emu_run).
 *
 *   3. Symlink or copy the resulting libemu.so into
 *      android-app/app/src/main/jniLibs/arm64-v8a/libemu.so so Gradle
 *      picks it up for assemble.
 *
 * Until that lands, this translation unit is a placeholder — it shows
 * the JNI signature the Java side calls, and what the C side will do
 * once emu_run is extracted. Compiling it standalone right now would
 * produce an unresolved symbol on emu_run.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>

/* Forward declaration. Defined in emu/port/main.c after the v1c.2
 * refactor. */
extern int emu_run(int argc, char **argv);

JNIEXPORT jint JNICALL
Java_io_infernode_Emu_run(JNIEnv *env, jobject thiz, jobjectArray jargv)
{
	(void)thiz;

	const jsize n = (*env)->GetArrayLength(env, jargv);

	/* argv layout: [0] = "emu", [1..n] = caller args, [n+1] = NULL. */
	char **argv = (char **)calloc((size_t)n + 2, sizeof(char *));
	if (argv == NULL)
		return -1;

	argv[0] = strdup("emu");

	int i;
	for (i = 0; i < n; i++) {
		jstring s = (jstring)(*env)->GetObjectArrayElement(env, jargv, i);
		const char *cs = (*env)->GetStringUTFChars(env, s, NULL);
		argv[i + 1] = strdup(cs);
		(*env)->ReleaseStringUTFChars(env, s, cs);
		(*env)->DeleteLocalRef(env, s);
	}

	const int rc = emu_run(n + 1, argv);

	for (i = 0; i <= n; i++)
		free(argv[i]);
	free(argv);

	return (jint)rc;
}
