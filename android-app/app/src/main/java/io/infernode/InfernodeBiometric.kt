package io.infernode

import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.fragment.app.FragmentActivity
import java.util.concurrent.Executor

/**
 * BiometricPrompt scaffolding for InferNode keyring/secstore unlock (INFR-173).
 *
 * The Inferno side (shared `appl/wm/settings.b`, `boot.sh`'s keyring-auth path)
 * already supports a "keyring auth" mode for the LLM connection — the
 * remote-LLM mount uses a keyfile at `/lib/keyring/serve-llm` and the boot
 * sequence asks factotum to authenticate with it. iOS hooks this to Face ID /
 * Touch ID via LocalAuthentication; Android needs the equivalent via
 * `androidx.biometric.BiometricPrompt`. That's what this class provides.
 *
 * Scope of this scaffold:
 *
 *   * `availability()` — does the device offer a usable biometric?
 *     Returns one of the BiometricManager.BIOMETRIC_* constants so callers can
 *     decide whether to surface the unlock affordance.
 *   * `authenticate(activity, callback)` — present BiometricPrompt; on success,
 *     fire the callback. The caller can then unblock keyring access (e.g. write
 *     a sentinel to `/tmp/.biometric-unlocked` that boot.sh / settings.b can
 *     stat the same way `secstoreunlocked()` does), or unwrap an Android-
 *     Keystore-bound secret.
 *
 * NOT in this scaffold (future work):
 *
 *   * Android Keystore secret binding. Wraps the secstore passphrase in a
 *     Keystore key requiring biometric auth, decrypts it on success, feeds it
 *     to `wm/logon` via stdin or a transient file. That's the production-grade
 *     keyring-auth flow; this scaffold stops at "user authenticated".
 *   * Integration with the boot sequence. The Activity currently always passes
 *     `--no-logon` (dev-iteration mode). Production wiring is a separate task.
 *   * StrongBox affinity. Devices that advertise hardware-backed StrongBox
 *     should prefer keys generated with `setIsStrongBoxBacked(true)`. Worth
 *     adding when we attach the Keystore secret layer.
 *
 * Design notes:
 *
 *   - The class is intentionally stateless and reusable; one instance per call
 *     site is fine.
 *   - We allow `DEVICE_CREDENTIAL` (PIN / pattern / password) as a fallback
 *     authenticator, so devices without enrolled biometrics still get a usable
 *     unlock affordance — matches iOS' Face-ID-falls-back-to-passcode UX.
 *   - The InferNode SDLActivity is a FragmentActivity (via SDLActivity's
 *     hierarchy in androidx) which is what BiometricPrompt requires.
 */
class InfernodeBiometric {

    /**
     * Probe whether a usable authenticator (biometric or device credential)
     * is enrolled on this device. Returns one of:
     *
     *  - [BiometricManager.BIOMETRIC_SUCCESS] — ready to authenticate
     *  - [BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE] — no biometric sensor
     *  - [BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE] — sensor present
     *    but temporarily unusable
     *  - [BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED] — sensor present,
     *    no fingerprints/faces registered. Caller may prompt the user to
     *    enrol via Settings.
     *  - [BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED] — rare;
     *    treat as unavailable.
     */
    fun availability(activity: FragmentActivity): Int {
        val bm = BiometricManager.from(activity)
        return bm.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_WEAK or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        )
    }

    /**
     * Surface BiometricPrompt. The activity must be a FragmentActivity (it is
     * — SDLActivity extends it through androidx). Fires [onAuthenticated]
     * exactly once on success, [onFailed] exactly once on a terminal failure
     * (user cancelled, too many attempts, hardware unavailable). Errors that
     * aren't terminal (e.g. one wrong fingerprint try) are absorbed by the
     * prompt itself; the user can retry within the same prompt session.
     *
     * `title` and `subtitle` show in the system biometric sheet. Keep them
     * short and obviously about InferNode unlock, not generic "authenticate".
     */
    fun authenticate(
        activity: FragmentActivity,
        title: String = "Unlock InferNode keyring",
        subtitle: String = "Use your fingerprint, face, or device PIN to access the LLM key.",
        onAuthenticated: () -> Unit,
        onFailed: (errorCode: Int, errorMessage: String) -> Unit = { _, _ -> }
    ) {
        val executor: Executor = activity.mainExecutor
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                Log.i(TAG, "biometric: succeeded (type=${result.authenticationType})")
                onAuthenticated()
            }

            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                Log.w(TAG, "biometric: error code=$errorCode msg=$errString")
                onFailed(errorCode, errString.toString())
            }

            override fun onAuthenticationFailed() {
                // Non-terminal: a single biometric attempt didn't match.
                // The prompt stays up; user can try again. Don't fire onFailed
                // here — wait for onAuthenticationError if the user exhausts
                // attempts or cancels.
                Log.d(TAG, "biometric: attempt failed (retry available)")
            }
        }

        val prompt = BiometricPrompt(activity, executor, callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            // Accept BIOMETRIC_WEAK (face/fingerprint without StrongBox) or
            // DEVICE_CREDENTIAL (PIN/pattern/password) — matches the iOS
            // "Face ID falls back to passcode" UX. Bumping to BIOMETRIC_STRONG
            // would gate on StrongBox-backed sensors only; revisit when we
            // bind a Keystore secret that requires it.
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_WEAK or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            // Confirmation requirement — Android default is true for weak
            // biometrics on some OEMs; explicit false avoids an extra tap on
            // a quick unlock. Stays compliant with the device's security
            // posture (DEVICE_CREDENTIAL always confirms via the credential
            // sheet).
            .setConfirmationRequired(false)
            .build()
        prompt.authenticate(info)
    }

    companion object {
        private const val TAG = "InfernodeBiometric"
    }
}
