// InferNode app module.
//
// Strategy: the C/asm build is driven by our existing Inferno mkfiles
// via build-android-ndk-arm64.sh. Gradle does NOT call mk; it expects
// libemu.so to be produced by the wrapper script before assemble, and
// just packages it into the APK's jniLibs/arm64-v8a/. This keeps the
// two build systems decoupled — Inferno's mk stays the source of truth
// for the runtime, Gradle handles the Android-shell side only.

import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Release signing (Play upload key). Credentials resolve in this order:
//   1. android-app/keystore.properties   — local dev, gitignored, never committed
//   2. environment variables             — CI: INFERNODE_UPLOAD_*
// If neither resolves, the release build is left UNSIGNED so that debug
// builds and contributor checkouts without the key still assemble. Only a
// machine holding the upload key produces a Play-uploadable signed artifact.
//
// With Play App Signing, this is the *upload* key, not the app key Google
// serves to users — losing it is recoverable via Play Console.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) FileInputStream(keystorePropsFile).use { load(it) }
}
fun signingValue(propKey: String, envKey: String): String? =
    keystoreProps.getProperty(propKey) ?: System.getenv(envKey)

val uploadStorePath = signingValue("storeFile", "INFERNODE_UPLOAD_KEYSTORE")
val haveUploadKey = uploadStorePath != null && file(uploadStorePath).exists()

android {
    namespace = "io.infernode"
    compileSdk = 35
    ndkVersion = "29.0.0"   // matches the toolchain build-android-ndk-arm64.sh uses

    defaultConfig {
        applicationId = "io.infernode"
        minSdk = 28         // matches mkfiles/mkfile-Android-arm64 API floor
        targetSdk = 35
        versionCode = 2
        versionName = "0.1.0"

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

    signingConfigs {
        // Created only when an upload key is available (see haveUploadKey
        // above); otherwise the release build stays unsigned and assembles
        // fine for contributors who don't hold the key.
        if (haveUploadKey) {
            create("release") {
                storeFile = file(uploadStorePath!!)
                storePassword = signingValue("storePassword", "INFERNODE_UPLOAD_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "INFERNODE_UPLOAD_KEY_ALIAS") ?: "upload"
                keyPassword = signingValue("keyPassword", "INFERNODE_UPLOAD_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Sign the release (AAB/APK) with the upload key when present.
            // The Play-uploadable artifact is produced by `./gradlew bundleRelease`
            // → app/build/outputs/bundle/release/app-release.aab
            if (haveUploadKey) {
                signingConfig = signingConfigs.getByName("release")
            }
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
