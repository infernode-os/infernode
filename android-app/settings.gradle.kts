// Phase 1c hellaphone (INFR-107 / INFR-110).
//
// Gradle settings for the InferNode Android app. The app shell lives in
// android-app/app/ and consumes a prebuilt libemu.so produced by the
// existing build-android-ndk-arm64.sh + (eventually) build-android-apk.sh
// drivers — i.e. Gradle is not the source of truth for the C build, it
// just packages the artefacts.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "infernode"
include(":app")
