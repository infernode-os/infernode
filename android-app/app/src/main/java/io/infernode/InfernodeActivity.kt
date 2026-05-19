package io.infernode

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.content.res.AssetManager
import android.os.Bundle
import android.text.method.ScrollingMovementMethod
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import kotlin.concurrent.thread

/**
 * Phase 2a Activity — interactive Inferno shell inside the APK.
 *
 * Previous phases (1c branding, 1d threading) proved emu boots inside
 * libemu.so without taking the JVM down with it. This phase wires the
 * I/O the other direction: a stdin pipe so the user can type commands,
 * and an output listener so emu's stdout shows up in the Activity
 * (not just `adb logcat`).
 *
 * Layout (top-to-bottom): scrolling output view, input row (EditText
 * + Send button). The whole thing is a plain View hierarchy — Compose
 * is Phase 2b. Keeping it minimal here so the integration concern
 * (does the pipe wiring actually work end-to-end?) is testable
 * independently of UI choice.
 *
 * Boot is automatic on onCreate. The Phase 1c/1d boot button is
 * gone — emu_run is safe now.
 */
class InfernodeActivity : Activity(), Emu.OutputListener {

    private lateinit var outputView: TextView
    private lateinit var outputScroll: ScrollView
    private lateinit var inputView: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildLayout())
        ensureRecordAudioPermission()

        Emu.setOutputListener(this)
        thread(name = "emu-boot") { bootInferno() }
    }

    override fun onDestroy() {
        // Release the native global ref. emu itself keeps running in
        // the background — the process stays alive even after the
        // Activity goes away — but without a listener the output
        // just goes to logcat until the Activity comes back.
        Emu.setOutputListener(null)
        super.onDestroy()
    }

    /**
     * OutputListener.onLine runs on a JNI-attached pthread, not the
     * UI thread. Marshal to the UI thread before touching views.
     */
    override fun onLine(line: String) {
        runOnUiThread {
            outputView.append(line)
            outputView.append("\n")
            outputScroll.post { outputScroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    private fun buildLayout(): LinearLayout {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(16, 16, 16, 16)
        }

        outputView = TextView(this).apply {
            text = "InferNode v0.1.0-phase2a\nBooting Inferno...\n"
            typeface = android.graphics.Typeface.MONOSPACE
            textSize = 13f
            setTextIsSelectable(true)
            movementMethod = ScrollingMovementMethod()
        }

        outputScroll = ScrollView(this).apply {
            addView(
                outputView,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        root.addView(
            outputScroll,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0,
                /* weight = */ 1f
            )
        )

        val inputRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        inputView = EditText(this).apply {
            hint = "type a command, e.g. ls /dis"
            typeface = android.graphics.Typeface.MONOSPACE
            isSingleLine = true
            setOnEditorActionListener { _, _, _ ->
                sendCurrentInput()
                true
            }
        }
        val sendButton = Button(this).apply {
            text = "Send"
            setOnClickListener { sendCurrentInput() }
        }
        inputRow.addView(
            inputView,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
        )
        inputRow.addView(
            sendButton,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        root.addView(
            inputRow,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        return root
    }

    private fun sendCurrentInput() {
        val line = inputView.text.toString()
        // Echo locally so the user sees what they typed (the Inferno
        // shell on the other side of the pipe will reflect this back
        // too if cons echo is on, but echoing here makes the UI feel
        // responsive regardless of cons mode).
        outputView.append("> $line\n")
        Emu.writeStdin("$line\n")
        inputView.text.clear()
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

    private fun bootInferno() {
        val infernoRoot = File(filesDir, "inferno-root").apply { mkdirs() }
        extractAssetsIfNeeded(infernoRoot)

        // -s: skip emu trap-handler installs — they'd clobber the
        //     JVM's signal handlers and crash the process (INFR-111).
        // -c1: arm64 JIT.
        // -r: Inferno root = extracted asset tree under filesDir.
        // /dis/sh.dis: boot the Inferno shell. Now that stdin is a
        //     real pipe (Phase 2a), the shell stays alive waiting
        //     for input instead of EOFing.
        val rc = Emu.run(
            arrayOf("-s", "-c1", "-r", infernoRoot.absolutePath, "/dis/sh.dis")
        )
        if (rc != 0) {
            runOnUiThread {
                outputView.append("Emu.run failed (rc=$rc)\n")
            }
        }
    }

    /**
     * Extract /dis/, /lib/, /module/ from APK assets to filesDir on
     * first launch. Idempotent: skipped if the version marker is
     * present.
     */
    private fun extractAssetsIfNeeded(root: File) {
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
}
