// Top-level Gradle build. AGP/Kotlin versions pinned for reproducibility;
// bump deliberately and verify against the AAudio + NDK r29 build flow.
//
// AGP 8.13.x is what we build compileSdk 36 (Android 16) with. AGP 8.7
// predates API 36: it was only tested up to compileSdk 35 and building
// against 36 on it means either an unsupported-compileSdk warning on every
// build or papering over it with android.suppressUnsupportedCompileSdk —
// neither is a good posture for a Play-shipping artefact. The Gradle
// wrapper moves in lockstep (AGP 8.13 needs Gradle 8.13+); JDK 17 still
// satisfies both, so the CI setup-java pin is unchanged.

plugins {
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.1.21" apply false
}
