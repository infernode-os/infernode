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
 * Phase 1d Activity (INFR-111). The Phase 1c scaffold deferred
 * `emu_run()` invocation behind an opt-in button because the call
 * SIGKILLed the process. Phase 1d makes the button actually work:
 *
 *   1. jni-emu.c spawns a detached pthread for emu_run, so the
 *      JVM-attached JNI thread returns immediately and emu's
 *      eventual pthread_exit lands on a thread the JVM doesn't track.
 *
 *   2. The argv below includes `-s` ("no trap handling") which tells
 *      emu to skip installing SIGILL/SIGFPE/SIGBUS/SIGSEGV handlers.
 *      Without this flag emu overwrites the JVM's signal handlers in
 *      libinit, and the first JVM-internal SIGSEGV (used for null-
 *      pointer-exception, GC barriers, etc.) routes to emu's
 *      trapmemref, which panics from a non-Inferno-Proc context and
 *      kills the process. -s is the correct Phase 1d flag; the
 *      Phase 2+ work is a proper chained-handler scheme so emu can
 *      catch Limbo runtime traps on Android without clobbering the
 *      JVM.
 *
 *   3. stdio (fd1/fd2) is captured in JNI_OnLoad and routed to
 *      logcat under the "InferNode" tag so emu's print() output
 *      surfaces in the device log instead of /dev/null.
 *
 * The Activity itself is unchanged in shape — single console TextView
 * and a boot button. Replacing it with a Compose chat UI is Phase 2.
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
            text = "InferNode APK v0.1.0-phase1d\n" +
                "libemu.so loaded; tap below to boot Inferno. " +
                "emu output appears in logcat under tag \"InferNode\" " +
                "(adb logcat -s InferNode:*).\n"
        }
        bootButton = Button(this).apply {
            text = "Boot Inferno"
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

        // -s: skip emu's trap-handler installation. Required on Android
        // so libinit doesn't overwrite the JVM's SIGSEGV/SIGBUS/SIGILL/
        // SIGFPE handlers. See INFR-111 / class doc for the rationale.
        //
        // -c1: JIT compile (the A55 is arm64 and the ARM64 JIT works).
        // -r:  set Inferno root to filesDir/inferno-root, where
        //      extractAssetsIfNeeded unpacked the dis/ + lib/ + module/
        //      trees from the APK assets.
        // /dis/sh.dis: boot the Inferno shell. It will EOF on stdin
        //      almost immediately (Android JNI stdin is /dev/null) and
        //      idle in the kproc loop — the process stays alive but no
        //      further commands run until a real stdin pipe is wired
        //      up (Phase 2 work).
        val exit = Emu.run(
            arrayOf("-s", "-c1", "-r", infernoRoot.absolutePath, "/dis/sh.dis")
        )
        // emu_run returns immediately in Phase 1d (the JNI bridge
        // spawns a detached pthread). A non-zero return here means the
        // bridge refused to launch, not that emu itself exited.
        post("emu launched (jni rc=$exit)\nWatch logcat for boot output.\n")
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
