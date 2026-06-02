package io.infernode

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.libsdl.app.SDLActivity
import java.io.File
import java.io.FileOutputStream

/**
 * Phase 2b.1 Activity — SDL3-hosted variant for the Lucifer / wm port.
 *
 * Two activities coexist in this APK:
 *
 *   * [InfernodeActivity]    — the Phase 2a interactive shell, an
 *                              ordinary View hierarchy on top of a
 *                              headless emu boot.
 *   * [InfernodeSDLActivity] — *this* class, an SDLActivity subclass
 *                              that hands the screen to SDL3 so emu's
 *                              draw-sdl3 backend can render Lucifer.
 *
 * SDL3 owns the lifecycle of this Activity completely — surface
 * creation, input dispatch, IME, pause/resume. We just point it at
 * the right shared libraries and provide the argv that gets passed
 * to `SDL_main` (defined in jni-emu.c when -DGUI_SDL3 is set).
 *
 * The Inferno asset tree is extracted into `filesDir/inferno-root/`
 * on first launch (same shape as [InfernodeActivity]). emu then
 * boots with `-r` pointing at that directory.
 */
class InfernodeSDLActivity : SDLActivity() {

    /**
     * Load order matters: libSDL3 first, then libemu (which declares
     * libSDL3.so as a NEEDED entry and resolves SDL_* symbols against
     * it at load time). PackageManager already has them in
     * jniLibs/arm64-v8a/ thanks to build-android-apk.sh --gui sdl3.
     */
    override fun getLibraries(): Array<String> = arrayOf("SDL3", "emu")

    /**
     * `getMainSharedObject` tells SDL3 which loaded library to look
     * up SDL_main in. Default is "main" → libmain.so; ours is in
     * libemu.so.
     */
    override fun getMainSharedObject(): String = "libemu.so"

    /**
     * Symbol to call as the application entry. Default is "SDL_main";
     * jni-emu.c defines it when -DGUI_SDL3 is on.
     */
    override fun getMainFunction(): String = "SDL_main"

    /**
     * argv passed to SDL_main. Mirrors the canonical macOS/Linux
     * developer-launch shape from CLAUDE.md:
     *
     *   emu -c1 -pheap=... -r$ROOT sh -l /lib/lucifer/boot.sh
     *
     * `sh -l /lib/lucifer/boot.sh` is what actually brings Lucifer up:
     * sh runs as a login shell so /lib/sh/profile fires (sets up /n,
     * mntgen, secstore binds, etc.), then boot.sh executes wm/logon
     * which puts the login screen + window manager on screen.
     *
     * Trying to invoke /dis/wm/wm.dis directly skips both stages and
     * dies with "mount /mnt/wm: '/mnt' file does not exist" — Phase
     * 2b.1's first integration on the A55 showed exactly this.
     *
     * Pool sizes: the macOS launch passes -pheap/-pmain/-pimage=1024m
     * each. Inferno's default pools are stingy and Lucifer + Veltro +
     * an LLM client outgrow them. Match the desktop launch numbers
     * here; the A55 has 8 GB and we're a single foreground app.
     */
    override fun getArguments(): Array<String> {
        val infernoRoot = File(filesDir, "inferno-root")
        val args = mutableListOf(
            "-s",
            // JIT compile mode is ABI-aware. arm64-v8a uses -c1 (the
            // libinterp/comp-arm64.c JIT is the validated, shipped path
            // and is what every phone runs). x86_64 falls back to -c0
            // (interpreter only) because libinterp/comp-amd64.c hasn't
            // been validated against Bionic yet — without the override
            // the APK SIGSEGVs in rungc walking partially-compiled
            // Modlinks on the emulator. Flip x86_64 to -c1 once the
            // amd64 JIT is validated (INFR-67 follow-up).
            jitFlagForRuntime(),
            "-pheap=1024m",
            "-pmain=1024m",
            "-pimage=1024m",
            "-r", infernoRoot.absolutePath,
            "sh",
            // boot-mobile.sh applies mobile-only setup (bigger fonts,
            // future hit-target tuning, swipe-nav hooks) and then
            // sources the regular boot.sh. Keeps desktop boot.sh
            // untouched.
            "-l", "/lib/lucifer/boot-mobile.sh",
        )
        if (DEV_SKIP_LOGON) {
            args += "--no-logon"
        }
        return args.toTypedArray()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Asset extraction has to happen *before* SDLActivity.onCreate
        // calls SDL_main: emu's argv references the root directory.
        extractInfernoRootIfNeeded()
        InfernodePhoneBridge.attach(this)
        super.onCreate(savedInstanceState)

        // Runtime permissions (mic, call, SMS) must be requested *after*
        // super.onCreate() and in a single batched call. Two faults bit
        // us before (crash on fresh install, INFR-211 follow-up):
        //
        //  1. super.onCreate() is where SDLActivity.loadLibraries()
        //     loads libSDL3 / libemu. SDL overrides
        //     onRequestPermissionsResult to call the *native*
        //     nativePermissionResult(). Any permission result delivered
        //     before the native lib is loaded throws UnsatisfiedLinkError
        //     and kills the app.
        //  2. Android serialises permission dialogs. Firing several
        //     requestPermissions() calls back-to-back makes the framework
        //     deliver a *synchronous* cancellation for the 2nd+ request —
        //     which, pre-load, is exactly fault (1). One batched request
        //     means one dialog sequence and one async callback.
        //
        // Dev devices never saw this: their permissions were already
        // granted, so requestPermissions() was never called. A fresh
        // Play Store install hits it on first launch.
        ensureRuntimePermissions()

        // Phase 2b.2 / INFR-115 — keep Lucifer's SDL surface inside the
        // safe rectangle (no overlap with the status bar at top or
        // gesture / nav bar at bottom).
        //
        // Android 15 (targetSdk=35) is edge-to-edge by default and
        // setDecorFitsSystemWindows(true) didn't actually inset the
        // SDLSurface — it kept extending to the screen edges. So we
        // stay edge-to-edge but pad the surface ourselves via
        // SDLActivity.mLayout (the SurfaceView's parent).
        //
        // Background: in edge-to-edge mode the system bars are a
        // transparent overlay. The status bar's white icons need to
        // contrast with whatever's underneath. The activity's default
        // window background is light (Theme.AppCompat.Light), which
        // showed through the top inset as a white bar that hid the
        // status bar icons. Force the window background to black —
        // matches Lucifer's brimstone palette (#080808) and gives the
        // status bar icons a dark backdrop. The Inferno wm draws over
        // it inside the safe rectangle.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.setBackgroundDrawable(ColorDrawable(Color.BLACK))

        val layout = mLayout
        if (layout != null) {
            ViewCompat.setOnApplyWindowInsetsListener(layout) { v, insets ->
                // System bars + display cutout: permanent safe-area
                // (status bar, notch, navigation bar).
                val bars = insets.getInsets(
                    WindowInsetsCompat.Type.systemBars()
                            or WindowInsetsCompat.Type.displayCutout()
                )
                // IME (soft keyboard): transient inset that grows when
                // the keyboard opens. Lucifer's text input row lives at
                // the very bottom of the canvas; without this inset the
                // keyboard hides it. iOS handles the same problem in
                // shared draw-sdl3 via SDL_SetTextInputArea (see
                // update_text_input_area, gated TARGET_OS_IOS) — this
                // is the Android counterpart of that fix. Same behaviour
                // visible to the user, mechanism differs because Android
                // soft-keyboard avoidance goes through Insets, not SDL.
                val ime = insets.getInsets(WindowInsetsCompat.Type.ime())
                val bottom = if (ime.bottom > bars.bottom) ime.bottom else bars.bottom
                Log.i(
                    TAG,
                    "applying insets: top=${bars.top} bottom=$bottom " +
                        "left=${bars.left} right=${bars.right} " +
                        "(bars.bottom=${bars.bottom} ime.bottom=${ime.bottom})"
                )
                v.setPadding(bars.left, bars.top, bars.right, bottom)
                WindowInsetsCompat.CONSUMED
            }
        } else {
            Log.w(TAG, "mLayout was null in onCreate; safe-area insets not applied")
        }

        Log.i(TAG, "InfernodeSDLActivity created; SDL_main will boot wm")
    }

    /**
     * Request every runtime permission the app needs in one batched
     * call. Single dialog sequence, single request code — see the long
     * note in [onCreate] for why batching + post-super ordering is
     * load-bearing.
     *
     *   * RECORD_AUDIO — AAudio capture in /dev/audio (returns zeros
     *     without it).
     *   * CALL_PHONE   — INFR-201: InfernodePhoneBridge.dial fires
     *     ACTION_CALL without bouncing through the system dialer.
     *   * SEND_SMS     — INFR-182: InfernodePhoneBridge.sendSms calls
     *     SmsManager.sendTextMessage.
     *   * RECEIVE_SMS / READ_SMS — INFR-182: InfernodeSmsReceiver picks
     *     up SMS_RECEIVED. Same perm group, granted together.
     *
     * Android collapses consecutive prompts within a group, so the user
     * sees one dialog per group, not one per permission.
     */
    private fun ensureRuntimePermissions() {
        val wanted = arrayOf(
            Manifest.permission.RECORD_AUDIO,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.SEND_SMS,
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
        )
        val missing = wanted.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            ActivityCompat.requestPermissions(
                this,
                missing.toTypedArray(),
                REQ_RUNTIME_PERMS
            )
        }
    }

    /**
     * Intercept the result for our batched runtime-permission request so
     * it does *not* reach SDLActivity.onRequestPermissionsResult — that
     * override calls the native nativePermissionResult() with the request
     * code, but SDL never issued REQ_RUNTIME_PERMS and treating it as an
     * SDL request is wrong. Our permissions are read via
     * checkSelfPermission at point of use (audio capture, dialing, SMS),
     * not through SDL's callback, so swallowing the result here is safe.
     * SDL's own permission flow uses its own request codes and still
     * forwards to super.
     */
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == REQ_RUNTIME_PERMS) {
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    /**
     * Pick the JIT compile-mode flag (-c0 / -c1) based on the running
     * ABI. Returns "-c1" on arm64-v8a (the validated JIT path), "-c0"
     * everywhere else.  Build.SUPPORTED_ABIS[0] is the preferred ABI
     * the loader chose for this process, which is what Android's
     * dynamic loader picked when loading libemu.so out of jniLibs/
     * — so it matches the architecture libemu.so was compiled for.
     */
    private fun jitFlagForRuntime(): String {
        val abi = Build.SUPPORTED_ABIS.firstOrNull() ?: ""
        return if (abi == "arm64-v8a") "-c1" else "-c0"
    }

    private fun extractInfernoRootIfNeeded() {
        val root = File(filesDir, "inferno-root").apply { mkdirs() }
        // .extracted-v2 — bumped from v1 when fonts/ was added to the
        // asset staging (INFR-115). Devices that already extracted at
        // v1 won't have fonts/ unless they re-extract.
        val marker = File(root, ".extracted-v2")
        // Re-extract whenever the installed APK is newer than our last
        // extraction. Without this, every `adb install -r` (and every
        // user-side APK upgrade) would leave the previous .dis tree on
        // disk and silently ignore the new APK's runtime — surfacing as
        // "I rebuilt and reinstalled but my fix isn't there", and the
        // only escape was `pm clear`. copyAssetTree overwrites in place,
        // so user-added files outside the asset tree (e.g. anything
        // under usr/inferno/) survive.
        val installTime = try {
            packageManager.getPackageInfo(packageName, 0).lastUpdateTime
        } catch (e: Exception) { 0L }
        if (marker.exists() && marker.lastModified() >= installTime) return
        copyAssetTree(assets, "inferno-root", root)
        marker.createNewFile()
        marker.setLastModified(System.currentTimeMillis())
    }

    private fun copyAssetTree(am: AssetManager, src: String, dst: File) {
        val children = am.list(src) ?: emptyArray()
        if (children.isEmpty()) {
            dst.parentFile?.mkdirs()
            am.open(src).use { input ->
                FileOutputStream(dst).use { output -> input.copyTo(output) }
            }
            return
        }
        dst.mkdirs()
        for (child in children) {
            val childSrc = if (src.isEmpty()) child else "$src/$child"
            copyAssetTree(am, childSrc, File(dst, child))
        }
    }

    companion object {
        private const val TAG = "InfernodeSDL"

        /**
         * Request code for our single batched runtime-permission request.
         * Deliberately high and distinctive so it never collides with the
         * codes SDL issues from its native side; [onRequestPermissionsResult]
         * also intercepts it before it can reach SDL.
         */
        private const val REQ_RUNTIME_PERMS = 1001

        /**
         * TEMPORARY: skip wm/logon during mobile dev iteration.
         *
         * Typing a password on every test rebuild is wasted time when
         * iterating on fonts / layouts / hit-targets. When this is
         * true, the Activity appends `--no-logon` to the argv;
         * /lib/lucifer/boot-mobile.sh forwards it as `$skiplogon=1`;
         * /lib/lucifer/boot.sh skips wm/logon. secstore stays locked,
         * factotum has no keys — LLM/keyring features won't work in
         * this mode.
         *
         * Flip back to `false` once we're past the UI iteration phase
         * and ready to wire INFR-117 (LLM in the APK), which needs
         * factotum to be populated.
         */
        private const val DEV_SKIP_LOGON = true
    }
}
