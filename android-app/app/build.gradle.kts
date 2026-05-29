// InferNode app module.
//
// Strategy: the C/asm build is driven by our existing Inferno mkfiles
// via build-android-ndk-arm64.sh. Gradle does NOT call mk; it expects
// libemu.so to be produced by the wrapper script before assemble, and
// just packages it into the APK's jniLibs/arm64-v8a/. This keeps the
// two build systems decoupled — Inferno's mk stays the source of truth
// for the runtime, Gradle handles the Android-shell side only.

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "io.infernode"
    compileSdk = 35
    ndkVersion = "29.0.0"   // matches the toolchain build-android-ndk-arm64.sh uses

    defaultConfig {
        applicationId = "io.infernode"
        minSdk = 28         // matches mkfiles/mkfile-Android-arm64 API floor
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-phase1c"

        ndk {
            // Ship every ABI for which we have a cross-built libemu.so
            // staged in jniLibs/. build-android-apk.sh produces these:
            //   --abi=arm64-v8a (default)  → phone hardware
            //   --abi=x86_64               → Android emulator on x86 hosts
            //   --abi=both                 → multi-arch APK
            // Listing both here is harmless when only one is built —
            // Gradle silently skips ABIs that have no jniLibs entries.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // libemu.so is built outside Gradle. Pick it up from the Inferno
    // build output path the wrapper script writes to.
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    // The dis/ runtime tree ships as APK assets and is extracted on
    // first launch into the app's private files dir, then handed to
    // emu via the -r flag.
    sourceSets["main"].assets.srcDirs("src/main/assets")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            // Debug APKs are signed with the Android debug keystore by
            // default. Sufficient for adb install on dev devices.
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    // BiometricPrompt (INFR-173): Face/Touch ID-equivalent unlock surface for
    // the Inferno keyring/secstore credential plumbing. The Limbo side already
    // has the keyring-auth control (shared appl/wm/settings.b); this is the
    // platform-native bridge that gates secret retrieval on biometric.
    implementation("androidx.biometric:biometric:1.1.0")
}
