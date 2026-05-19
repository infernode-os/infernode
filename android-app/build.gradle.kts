// Top-level Gradle build. AGP/Kotlin versions pinned for reproducibility;
// bump deliberately and verify against the AAudio + NDK r29 build flow.

plugins {
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
}
