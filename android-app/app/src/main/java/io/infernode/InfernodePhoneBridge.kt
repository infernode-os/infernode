package io.infernode

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.SmsManager
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
     * Threading: invoked on an AttachCurrentThread'd Inferno kproc
     * pthread whose stack is ~28 KB — far too small for the
     * startActivity → ActivityManager binder roundtrip (StackOverflowError
     * shows up in logcat tagged with our TAG if you try). We post the
     * actual dispatch to the main thread, where the stack is the system
     * default. Trade: we lose the in-band error result, so we report
     * success/fail asynchronously via logcat and return 0 to the caller
     * unconditionally once the post is scheduled. The pre-flight checks
     * (context null, permission denied) still run synchronously and
     * return -1 — those are the cases where the C side genuinely needs
     * to know the dial won't happen.
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
        Handler(Looper.getMainLooper()).post {
            try {
                val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$number")).apply {
                    // FLAG_ACTIVITY_NEW_TASK is mandatory when starting an
                    // Activity from a non-Activity Context (we hold an
                    // applicationContext, not an Activity ref — see attach()).
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                ctx.startActivity(intent)
                Log.i(TAG, "dial($number): ACTION_CALL dispatched on main thread")
            } catch (se: SecurityException) {
                Log.w(TAG, "dial($number): SecurityException — ${se.message}")
            } catch (t: Throwable) {
                Log.w(TAG, "dial($number): ${t.javaClass.simpleName} — ${t.message}")
            }
        }
        return 0
    }

    /**
     * INFR-182 SMS-send slice: ship one SMS via SmsManager.
     *
     * Called from emu/Android/phonebridge.c's `phonebridge_send_sms`
     * when the agent writes `send <number> <body>` to `/phone/sms`.
     *
     * Returns 0 on success (SmsManager call dispatched), -1 on a
     * synchronous failure (no context, permission denied, no
     * SmsManager service). Delivery itself is asynchronous — the
     * carrier outcome lands in logcat tagged InfernodePhoneBridge if
     * you want to follow it; we don't propagate delivery success back
     * to the C side because devphone's write semantics are
     * fire-and-forget (matches the iOS path's compose-sheet model —
     * see emu/iOS/phonebridge.m).
     *
     * Long messages (>160 GSM-7 / 70 UCS-2) are split via
     * `divideMessage` + `sendMultipartTextMessage` so the receiver
     * gets the whole thing.
     */
    @JvmStatic
    fun sendSms(number: String, body: String): Int {
        val ctx = appContext
        if (ctx == null) {
            Log.w(TAG, "sendSms($number): no context attached — call attach() first")
            return -1
        }
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.SEND_SMS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Log.w(TAG, "sendSms($number): SEND_SMS not granted")
            return -1
        }
        val sms: SmsManager? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ctx.getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
        if (sms == null) {
            Log.w(TAG, "sendSms($number): SmsManager unavailable")
            return -1
        }
        Handler(Looper.getMainLooper()).post {
            try {
                val parts = sms.divideMessage(body)
                if (parts.size <= 1) {
                    sms.sendTextMessage(number, null, body, null, null)
                    Log.i(TAG, "sendSms($number): single-part dispatched (${body.length} chars)")
                } else {
                    sms.sendMultipartTextMessage(number, null, parts, null, null)
                    Log.i(TAG, "sendSms($number): ${parts.size}-part dispatched (${body.length} chars)")
                }
            } catch (se: SecurityException) {
                Log.w(TAG, "sendSms($number): SecurityException — ${se.message}")
            } catch (iae: IllegalArgumentException) {
                Log.w(TAG, "sendSms($number): IllegalArgumentException — ${iae.message}")
            } catch (t: Throwable) {
                Log.w(TAG, "sendSms($number): ${t.javaClass.simpleName} — ${t.message}")
            }
        }
        return 0
    }
}
