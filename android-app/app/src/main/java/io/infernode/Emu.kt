package io.infernode

/**
 * JNI bridge to the InferNode emulator (libemu.so).
 *
 * The C side lives in android-app/app/src/main/cpp/jni-emu.c.
 *
 * Threading: `run` is fire-and-forget. The native side spawns its
 * own pthread for emu and returns to Java immediately. `writeStdin`
 * is safe to call from any thread; the C side writes are atomic for
 * pipe-buffer-sized writes (PIPE_BUF, typically 4 KiB).
 *
 * Single-instance: emu can only boot once per process. A second
 * `run` returns -1.
 */
object Emu {

    /**
     * Output sink for emu's stdout/stderr. The native reader thread
     * calls [onLine] once per newline-terminated chunk it sees. Use
     * [setOutputListener] to register / clear.
     *
     * Implementations should be cheap and non-blocking — they run on
     * a JNI-attached pthread, not the Android UI thread. Marshal to
     * the UI via `Activity.runOnUiThread` or a `Handler`.
     */
    interface OutputListener {
        fun onLine(line: String)
    }

    init {
        System.loadLibrary("emu")
    }

    /**
     * Boot the emulator with the given argv. Mirrors `main(int argc, char **argv)`.
     *
     * Returns 0 on successful launch (emu is now running on its own
     * pthread), -1 if a previous Emu.run already claimed the slot.
     */
    @JvmStatic
    external fun run(argv: Array<String>): Int

    /**
     * Write bytes to emu's stdin. Caller appends `\n` for line input.
     * Returns the number of bytes written, or -1 on error.
     */
    @JvmStatic
    external fun writeStdin(data: String): Int

    /**
     * Register an output sink. Pass `null` to clear. The native side
     * holds a JNI global ref to the listener; the previous listener
     * is released. Only one listener at a time.
     */
    @JvmStatic
    external fun setOutputListener(listener: OutputListener?)
}
