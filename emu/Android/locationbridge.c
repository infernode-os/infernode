/*
 * locationbridge — Android: LocationManager, through
 * android-app/.../InfernodeLocationBridge.kt.
 *
 * start and stop call the Kotlin object's static start() and stop()
 * from the kproc that opened or closed #g/nmea; Kotlin posts the
 * LocationManager calls to the main looper (they need one, and a
 * kproc's stack is too small for a binder round trip) and returns, so
 * neither blocks.  Positions and state changes come back on the main
 * thread through the natives below, which hand them to devlocation.
 *
 * The class and its methods are cached in JNI_OnLoad (jni-emu.c calls
 * locationbridge_jni_init) for the reason phonebridge.c gives: from a
 * kproc's attached thread the app's classes are not visible.  The
 * headless o.emu has no JVM, and says so when #g/nmea is opened.
 */

#include <stdio.h>
#include <string.h>
#include <jni.h>
#include "locationbridge.h"

extern JavaVM *g_vm;	/* phonebridge.c */

static jclass	g_loc_class;
static jmethodID	g_loc_start;
static jmethodID	g_loc_stop;

void
locationbridge_jni_init(JNIEnv *env)
{
	jclass local;

	local = (*env)->FindClass(env, "io/infernode/InfernodeLocationBridge");
	if(local == NULL){
		(*env)->ExceptionClear(env);
		fprintf(stderr, "location: JNI_OnLoad: FindClass(InfernodeLocationBridge) failed\n");
		return;
	}
	g_loc_start = (*env)->GetStaticMethodID(env, local, "start", "()I");
	g_loc_stop = (*env)->GetStaticMethodID(env, local, "stop", "()V");
	if(g_loc_start == NULL || g_loc_stop == NULL){
		(*env)->ExceptionClear(env);
		(*env)->DeleteLocalRef(env, local);
		g_loc_start = g_loc_stop = NULL;
		fprintf(stderr, "location: JNI_OnLoad: start/stop not found\n");
		return;
	}
	g_loc_class = (*env)->NewGlobalRef(env, local);
	(*env)->DeleteLocalRef(env, local);
}

void
locationbridge_init(void)
{
}

/* the calling thread's JNIEnv, attaching it if need be */
static JNIEnv*
getenv_attached(int *attached)
{
	JNIEnv *env;

	*attached = 0;
	if(g_vm == NULL)
		return NULL;
	switch((*g_vm)->GetEnv(g_vm, (void**)&env, JNI_VERSION_1_6)){
	case JNI_OK:
		return env;
	case JNI_EDETACHED:
		if((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK)
			return NULL;
		*attached = 1;
		return env;
	}
	return NULL;
}

int
locationbridge_start(char *err, int errlen)
{
	JNIEnv *env;
	jint rc;
	int attached;

	if(g_loc_class == NULL){
		snprintf(err, errlen, "location: no JVM in this build");
		return -1;
	}
	env = getenv_attached(&attached);
	if(env == NULL){
		snprintf(err, errlen, "location: cannot attach to the JVM");
		return -1;
	}
	rc = (*env)->CallStaticIntMethod(env, g_loc_class, g_loc_start);
	if((*env)->ExceptionCheck(env)){
		(*env)->ExceptionClear(env);
		rc = -1;
	}
	if(attached)
		(*g_vm)->DetachCurrentThread(g_vm);
	if(rc < 0){
		snprintf(err, errlen, "location: no location service");
		return -1;
	}
	return 0;
}

void
locationbridge_stop(void)
{
	JNIEnv *env;
	int attached;

	if(g_loc_class == NULL)
		return;
	env = getenv_attached(&attached);
	if(env == NULL)
		return;
	(*env)->CallStaticVoidMethod(env, g_loc_class, g_loc_stop);
	if((*env)->ExceptionCheck(env))
		(*env)->ExceptionClear(env);
	if(attached)
		(*g_vm)->DetachCurrentThread(g_vm);
}

JNIEXPORT void JNICALL
Java_io_infernode_InfernodeLocationBridge_nativeFix(JNIEnv *env, jclass cls,
	jdouble lat, jdouble lon,
	jboolean hasalt, jdouble alt,
	jboolean hasspeed, jdouble speed,
	jboolean hascourse, jdouble course,
	jdouble hacc, jdouble vacc, jlong utcms)
{
	LocFix f;

	(void)env;
	(void)cls;
	memset(&f, 0, sizeof f);
	f.lat = lat;
	f.lon = lon;
	f.hasalt = hasalt;
	f.alt = alt;
	f.hasspeed = hasspeed;
	f.speed = speed;
	f.hascourse = hascourse;
	f.course = course;
	f.hacc = hacc;
	f.vacc = vacc;
	f.utcms = utcms;
	locationbridge_post_fix(&f);
}

JNIEXPORT void JNICALL
Java_io_infernode_InfernodeLocationBridge_nativeState(JNIEnv *env, jclass cls, jstring jstate)
{
	const char *s;

	(void)cls;
	if(jstate == NULL)
		return;
	s = (*env)->GetStringUTFChars(env, jstate, NULL);
	if(s == NULL)
		return;
	locationbridge_post_state(s);
	(*env)->ReleaseStringUTFChars(env, jstate, s);
}
