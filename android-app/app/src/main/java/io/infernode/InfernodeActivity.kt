package io.infernode

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
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
     * Extract /dis, /appl, /lib, /module (the runtime tree shipped as
     * APK assets) on first launch. Idempotent — skips if the marker
     * file is present.
     *
     * This is a placeholder: real implementation walks `assets.list()`
     * recursively and copies preserving structure. Stubbed here.
     */
    private fun extractAssetsIfNeeded(root: File) {
        val marker = File(root, ".extracted-v1")
        if (marker.exists()) return
        // TODO: walk and extract assets/ contents into `root`. See
        // INFR-110 for the design notes.
        marker.createNewFile()
    }

    private fun post(text: String) {
        runOnUiThread { consoleView.append(text) }
    }
}
