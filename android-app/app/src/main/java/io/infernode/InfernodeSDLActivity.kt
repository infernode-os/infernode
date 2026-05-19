package io.infernode

import android.content.res.AssetManager
import android.os.Bundle
import android.util.Log
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
        return arrayOf(
            "-s",
            "-c1",
            "-pheap=1024m",
            "-pmain=1024m",
            "-pimage=1024m",
            "-r", infernoRoot.absolutePath,
            "sh",
            "-l", "/lib/lucifer/boot.sh",
        )
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // Asset extraction has to happen *before* SDLActivity.onCreate
        // calls SDL_main: emu's argv references the root directory.
        extractInfernoRootIfNeeded()
        super.onCreate(savedInstanceState)
        Log.i(TAG, "InfernodeSDLActivity created; SDL_main will boot wm")
    }

    private fun extractInfernoRootIfNeeded() {
        val root = File(filesDir, "inferno-root").apply { mkdirs() }
        val marker = File(root, ".extracted-v1")
        if (marker.exists()) return
        copyAssetTree(assets, "inferno-root", root)
        marker.createNewFile()
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
    }
}
