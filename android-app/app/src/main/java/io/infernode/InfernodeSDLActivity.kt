package io.infernode

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
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
            "-c1",
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
        // Mic permission has to be requested at runtime — manifest
        // declaration alone is not enough on API >= 23. Kick the
        // dialog off before SDL takes the surface; AAudio capture in
        // /dev/audio would silently return zeros otherwise.
        ensureRecordAudioPermission()
        super.onCreate(savedInstanceState)

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
                val bars = insets.getInsets(
                    WindowInsetsCompat.Type.systemBars()
                            or WindowInsetsCompat.Type.displayCutout()
                )
                Log.i(
                    TAG,
                    "applying insets: top=${bars.top} bottom=${bars.bottom} " +
                        "left=${bars.left} right=${bars.right}"
                )
                v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
                WindowInsetsCompat.CONSUMED
            }
        } else {
            Log.w(TAG, "mLayout was null in onCreate; safe-area insets not applied")
        }

        Log.i(TAG, "InfernodeSDLActivity created; SDL_main will boot wm")
    }

    private fun ensureRecordAudioPermission() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                /* requestCode = */ 1
            )
        }
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
