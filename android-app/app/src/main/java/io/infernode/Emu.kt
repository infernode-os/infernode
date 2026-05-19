package io.infernode

/**
 * JNI bridge to the InferNode emulator (libemu.so).
 *
 * The C side lives in android-app/app/src/main/cpp/jni-emu.c and is
 * itself a thin wrapper over emu's `emu_run()` entry — the same path
 * used by the existing `main()` for the `adb shell /data/local/tmp/o.emu`
 * use case. JNI does no work other than translating argv between
 * Java and C.
 *
 * The library name `emu` resolves to `libemu.so`, which is produced by
 * `build-android-apk.sh` (a Phase 1c follow-up driver) from the same
 * Inferno mkfile chain that produces the standalone o.emu binary in
 * Phase 1a/1b.
 *
 * Threading: `run` blocks for the lifetime of the emulator. Call it
 * from a dedicated background thread (typically inside a
 * [InfernodeService]); the caller is responsible for not invoking it
 * twice in the same process — the emulator was historically not
 * designed for multiple instantiations and refactoring that out is
 * tracked separately.
 */
object Emu {

    init {
        System.loadLibrary("emu")
    }

    /**
     * Boot the emulator with the given argv. Mirrors `main(int argc, char **argv)`.
     *
     * Typical args:
     *   ["-c1", "-r", root, "/dis/sh.dis"]            # interactive shell
     *   ["-c1", "-r", root, "/dis/sh.dis", "/serve9p.b"]  # 9P daemon
     *
     * @param argv the argument vector, *without* the leading program name
     *             (the C side prepends "emu" itself).
     * @return the emulator's exit code.
     */
    @JvmStatic
    external fun run(argv: Array<String>): Int
}
