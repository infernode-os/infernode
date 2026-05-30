package io.infernode

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Phone bridge for INFR-201: native side calls into here from
 * emu/Android/phonebridge.c to originate a PSTN call.
 *
 * Why a separate class: the C bridge runs on a non-JVM pthread; it
 * AttachCurrentThread's, looks this class up by FQN, calls the static
 * `dial` method. Static-only API keeps the JNI shim trivial — no
 * jobject lifecycle to manage across the C/Kotlin boundary.
 *
 * Context handling: an Intent needs a Context to fire from. The C
 * thread doesn't have one. The Activity/Service registers one via
 * [attach] at startup; we hold it as a weak-ish application-scope
 * field (the Application object lives as long as the process, so a
 * plain reference is fine — there's no Activity-leak risk because we
 * never store an Activity, only the applicationContext).
 *
 * Permission contract: CALL_PHONE is declared in AndroidManifest and
 * granted at runtime by [ensureCallPhonePermission] in the Activity.
 * If the user denies it, [dial] returns -1 and the agent surfaces the
 * `permission denied` error path through devphone.
 */
object InfernodePhoneBridge {

    private const val TAG = "InfernodePhoneBridge"

    @Volatile
    private var appContext: Context? = null

    /**
     * Hand the bridge an applicationContext. Call once from the
     * Activity (or Service) onCreate; subsequent calls overwrite.
     * The C side is no-op until this has been called at least once.
     */
    @JvmStatic
    fun attach(ctx: Context) {
        appContext = ctx.applicationContext
        Log.i(TAG, "attached applicationContext for /phone bridge")
    }

    /**
     * Originate a PSTN call. Returns 0 on success (Intent dispatched),
     * -1 on any failure (no context, permission denied, no resolver).
     *
     * Called from emu/Android/phonebridge.c's `phonebridge_phone_ctl`
     * when the agent writes `dial <number>` to `/phone/phone`. The
     * number is whatever the agent passed — we don't reformat it here;
     * devphone strips the verb and trailing newline, and the host OS
     * parses the `tel:` URI on its end.
     *
     * Threading: invoked on a JVM-attached pthread from JNI. Intent
     * dispatch is thread-safe via startActivity; we don't bounce to
     * the main thread.
     */
    @JvmStatic
    fun dial(number: String): Int {
        val ctx = appContext
        if (ctx == null) {
            Log.w(TAG, "dial($number): no context attached — call attach() first")
            return -1
        }
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.CALL_PHONE)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "dial($number): CALL_PHONE not granted")
            return -1
        }
        return try {
            val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number")).apply {
                // FLAG_ACTIVITY_NEW_TASK is mandatory when starting an
                // Activity from a non-Activity Context (we hold an
                // applicationContext, not an Activity ref — see attach()).
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            Log.i(TAG, "dial($number): ACTION_CALL dispatched")
            0
        } catch (se: SecurityException) {
            Log.w(TAG, "dial($number): SecurityException — ${se.message}")
            -1
        } catch (t: Throwable) {
            Log.w(TAG, "dial($number): ${t.javaClass.simpleName} — ${t.message}")
            -1
        }
    }
}
