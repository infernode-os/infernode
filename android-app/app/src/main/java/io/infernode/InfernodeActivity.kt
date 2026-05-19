package io.infernode

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.LinearLayout
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
 *             -> wait for user tap on the "boot" button before
 *                spawning emu-boot (see DEFERRED_EMU_BOOT below)
 *
 * DEFERRED_EMU_BOOT — Phase 1c milestone is "the build path works":
 * APK assembled, libemu.so loaded, JNI entry callable. The actual
 * emu_run integration is Phase 1d, because emu's threading model
 * (libinit -> kproc(emuinit) -> for(;;) ospause(); ospause() does
 * pthread_exit(0)) tears down the calling thread. On Android that
 * thread is a JVM-managed JNI thread; pthread_exit on it is UB and
 * the zygote reaps the process with SIGKILL within ~20ms. Fix
 * requires either a fork()-and-exec-from-asset-dir scheme or a
 * proper Posix main-loop-on-detached-pthread refactor in emu/port.
 * The button below makes the crash opt-in so the build artefact
 * survives the smoke test until that work lands. See INFR-NEW
 * (Phase 1d emu_run/JNI lifecycle).
 */
class InfernodeActivity : Activity() {

    private lateinit var consoleView: TextView
    private lateinit var bootButton: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        consoleView = TextView(this).apply {
            text = "InferNode APK v0.1.0-phase1c\n" +
                "libemu.so loaded.\n" +
                "Tap to attempt emu_run() — known to SIGKILL the process " +
                "until the Phase 1d threading refactor lands.\n"
        }
        bootButton = Button(this).apply {
            text = "Boot Inferno (Phase 1d preview)"
            setOnClickListener {
                isEnabled = false
                post("Booting...\n")
                thread(name = "emu-boot") { bootInferno() }
            }
        }
        layout.addView(consoleView)
        layout.addView(bootButton)
        setContentView(layout)

        ensureRecordAudioPermission()
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
