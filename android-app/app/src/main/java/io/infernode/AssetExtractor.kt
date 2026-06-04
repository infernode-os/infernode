package io.infernode

import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.io.FileOutputStream

/**
 * Extracts the bundled Inferno asset tree (~48 MB) into the app's private
 * files dir. emu's `-r` argv points at `filesDir/inferno-root`, so this must
 * complete before SDL_main boots.
 *
 * Shared by [InfernodeSplashActivity] — which runs it on a BACKGROUND thread
 * before starting the SDL activity — and [InfernodeSDLActivity], which still
 * calls it as a fast no-op safety so a direct `am start` of the SDL activity
 * remains correct. It used to run synchronously in InfernodeSDLActivity.onCreate
 * and blocked the main thread (~2 s on an A55, an ANR risk on slower devices /
 * post-update re-extraction) — hence the move off the activity.
 */
object AssetExtractor {

    fun extractInfernoRootIfNeeded(ctx: Context) {
        val root = File(ctx.filesDir, "inferno-root").apply { mkdirs() }
        // .extracted-v2 — bumped from v1 when fonts/ was added to the asset
        // staging (INFR-115). Devices that extracted at v1 won't have fonts/
        // unless they re-extract.
        val marker = File(root, ".extracted-v2")
        // Re-extract whenever the installed APK is newer than our last
        // extraction. Without this, every `adb install -r` (and every user-side
        // APK upgrade) would leave the previous .dis tree on disk and silently
        // ignore the new APK's runtime — surfacing as "I rebuilt and reinstalled
        // but my fix isn't there", and the only escape was `pm clear`.
        // copyAssetTree overwrites in place, so user-added files outside the
        // asset tree (e.g. anything under usr/inferno/) survive.
        val installTime = try {
            ctx.packageManager.getPackageInfo(ctx.packageName, 0).lastUpdateTime
        } catch (e: Exception) { 0L }
        if (marker.exists() && marker.lastModified() >= installTime) return
        copyAssetTree(ctx.assets, "inferno-root", root)
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
}
