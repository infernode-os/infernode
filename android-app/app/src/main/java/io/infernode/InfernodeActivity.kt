package io.infernode

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

/**
 * Phase 1c v1 Activity — a text-only console placeholder.
 *
 * The shape of the UI here is intentionally minimal: this is the
 * "prove the build path end-to-end" milestone, not the design
 * milestone. Once everything links, a Compose-based real UI replaces
 * the TextView.
 *
 * Lifecycle:
 *   onCreate -> extract /dis/ assets to filesDir/inferno-root/
 *             -> request RECORD_AUDIO
 *             -> spawn worker thread that calls Emu.run(...) targeting
 *                /dis/sh.dis with stdin piped to the UI (TODO)
 */
class InfernodeActivity : Activity() {

    private lateinit var consoleView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consoleView = TextView(this).apply {
            text = "InferNode booting..."
            isClickable = false
            isLongClickable = false
        }
        setContentView(consoleView)

        ensureRecordAudioPermission()
        thread(name = "emu-boot") { bootInferno() }
    }

    private fun ensureRecordAudioPermission() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                /* requestCode = */ 1
            )
        }
    }

    private fun bootInferno() {
        val infernoRoot = File(filesDir, "inferno-root").apply { mkdirs() }
        extractAssetsIfNeeded(infernoRoot)
        post("Inferno root: ${infernoRoot.absolutePath}\n")
        val exit = Emu.run(
            arrayOf("-c1", "-r", infernoRoot.absolutePath, "/dis/sh.dis")
        )
        post("emu exited with status $exit\n")
    }

    /**
     * Extract the Inferno runtime tree shipped as APK assets (`dis/`,
     * `lib/`, `module/` under `assets/inferno-root/`) on first launch.
     * Idempotent: skipped if the version marker file is present, so
     * repeat starts are cheap.
     *
     * The version suffix on the marker (`.extracted-v1`) lets a future
     * APK release force a re-extract just by bumping the suffix when
     * the runtime tree changes. Bytecode is recompiled into the APK
     * with each release; users who upgrade get the new runtime
     * automatically.
     */
    private fun extractAssetsIfNeeded(root: File) {
        val marker = File(root, ".extracted-v1")
        if (marker.exists()) return
        copyAssetTree(assets, "inferno-root", root)
        marker.createNewFile()
    }

    /**
     * Recursively copy `src` (an asset path, relative to the APK's
     * assets/ root) into `dst` (a host directory). Preserves the
     * directory tree; files become regular files under `dst`.
     *
     * `AssetManager.list(path)` returns an empty array for files, which
     * is how we distinguish file-vs-dir nodes — there is no `isFile`
     * predicate on the asset namespace.
     */
    private fun copyAssetTree(am: AssetManager, src: String, dst: File) {
        val children = am.list(src) ?: emptyArray()
        if (children.isEmpty()) {
            // Leaf: copy as a regular file.
            dst.parentFile?.mkdirs()
            am.open(src).use { input ->
                FileOutputStream(dst).use { output -> input.copyTo(output) }
            }
            return
        }
        // Directory: recurse into each child.
        dst.mkdirs()
        for (child in children) {
            val childSrc = if (src.isEmpty()) child else "$src/$child"
            copyAssetTree(am, childSrc, File(dst, child))
        }
    }

    private fun logTag(): String = "InferNode"

    private fun post(text: String) {
        runOnUiThread { consoleView.append(text) }
    }
}
