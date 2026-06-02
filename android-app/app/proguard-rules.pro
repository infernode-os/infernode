# ProGuard/R8 rules for the InferNode Android app.
#
# These are PRECAUTIONARY: the release build currently sets
# isMinifyEnabled = false, so R8 does not shrink/obfuscate today. They are
# in place so that turning minify on later cannot silently break the JNI
# bridge between the emu native library and the Kotlin/Java shell.
#
# The hazard: the native side (jni-emu.c, emu/Android/phonebridge.c) reaches
# back into Java/Kotlin by string name via FindClass / GetMethodID /
# GetStaticMethodID. R8 has no way to see those references, so without
# -keep it would rename or strip the targets and the lookups would fail at
# runtime. Every keep below corresponds to a concrete native-side reference.

# --- Native method declarations (the Java_io_infernode_* entry points) -------
# `external fun` in Kotlin compiles to `native` methods; keep their names and
# declaring classes so the JNI symbol names stay stable.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# --- Emu JNI surface ---------------------------------------------------------
# Java_io_infernode_Emu_{run,writeStdin,setOutputListener} are called from
# jni-emu.c; setOutputListener stores a listener whose onLine(String) the
# native side invokes via GetMethodID by name (jni-emu.c:303).
-keep class io.infernode.Emu { *; }
-keep class io.infernode.Emu$OutputListener { *; }
-keepclassmembers class io.infernode.Emu$OutputListener {
    void onLine(java.lang.String);
}

# --- Phone bridge (INFR-201 / INFR-182) -------------------------------------
# phonebridge.c does FindClass("io/infernode/InfernodePhoneBridge") then
# GetStaticMethodID for "dial" and "sendSms"; postSms is a native method
# called the other direction. Keep the whole class.
-keep class io.infernode.InfernodePhoneBridge { *; }

# --- Biometric unlock bridge (INFR-173) -------------------------------------
-keep class io.infernode.InfernodeBiometric { *; }
-keep class io.infernode.InfernodeBiometric$* { *; }

# --- Components referenced from AndroidManifest.xml --------------------------
# AGP normally keeps manifest classes automatically; explicit for safety.
-keep class io.infernode.InfernodeActivity { *; }
-keep class io.infernode.InfernodeSDLActivity { *; }
-keep class io.infernode.InfernodeService { *; }
-keep class io.infernode.InfernodeSmsReceiver { *; }

# --- Vendored SDL3 Java layer ------------------------------------------------
# org.libsdl.app.* carries a large JNI callback surface (nativeXxx /
# onNativeXxx / HIDDevice* callbacks) all resolved by name from libSDL3.so.
# Keep the package wholesale rather than enumerate each callback.
-keep class org.libsdl.app.** { *; }
-keepclassmembers class org.libsdl.app.** {
    native <methods>;
}
