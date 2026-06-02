# Google Play submission readiness — InferNode

Status as of 2026-06-01. Package: `io.infernode`. Owner decisions are marked
**DECISION**; things only the account holder can do are marked **YOU**.

## Done (in this repo)

- [x] **Release signing wired** — `app/build.gradle.kts` reads upload-key
      creds from `keystore.properties` (gitignored) or `INFERNODE_UPLOAD_*`
      env vars. Release left unsigned if no key present, so contributor/debug
      builds still work. Template: `android-app/keystore.properties.example`.
- [x] **AAB is the Play artifact** — `./gradlew bundleRelease` →
      `app/build/outputs/bundle/release/app-release.aab` (signed when key present).
- [x] **ProGuard keeps** — `app/proguard-rules.pro` preserves the JNI bridge
      (`Java_io_infernode_*`, the `Emu`/`OutputListener` callbacks, the phone
      bridge, and the vendored `org.libsdl.app` layer). Precautionary; minify
      is still off.
- [x] **Adaptive launcher icon** — `mipmap-anydpi-v26/ic_launcher{,_round}.xml`
      + density-bucketed `ic_launcher_foreground.png` + black background color.
- [x] **Store graphics** — `icon-512.png` (512² listing icon),
      `feature-graphic-1024x500.png`.
- [x] **Legal/listing drafts** — `../PRIVACY.md`, `../SUPPORT.md`, `listing.md`.

## Blockers — must resolve before first upload

- [x] **Restricted SMS permissions — RESOLVED.** `SEND_SMS`/`RECEIVE_SMS`/
      `READ_SMS` are barred by Play policy for non-default-SMS apps. Stripped
      from the **release** build (the Play artifact) via the manifest overlay
      `app/src/release/AndroidManifest.xml` (`tools:node="remove"` on the three
      permissions and `InfernodeSmsReceiver`). The **debug/dev build keeps SMS**,
      so the feature stays available for development and sideload. Verified in
      the merged release manifest. `CALL_PHONE` is unrestricted and kept.
- [x] **`io.infernode` confirmed as the permanent package name.**
- [x] **Unused FOREGROUND_SERVICE_DATA_SYNC removed from release.** `InfernodeService`
      is Phase-1c scaffolding never started by the shipping app; declaring the
      permission triggered a Play demo-video requirement we can't honestly meet.
      Stripped from the release build (kept in debug) via `app/src/release/AndroidManifest.xml`.
      Bundle is now versionCode 3.
- [ ] **YOU: generate the upload keystore** (see `keystore.properties.example`)
      and create `android-app/keystore.properties`.
- [ ] **YOU: Play Console account confirmed**, $25 registration done.
- [x] **Privacy policy hosted at a public URL — LIVE.** `/privacy/` and
      `/support/` pages are deployed on the infernode.io site (Astro, repo
      `pdfinn/infernode.io`). Both verified returning HTTP 200:
      https://infernode.io/privacy/ and https://infernode.io/support/.

## Remaining before review submission

- [~] **Screenshots** — 2 captured at 1080×2340 (portrait phone) in
      `screenshots/`: `01-lucifer-home.png` (Veltro onboarding / accordion) and
      `02-fractals.png` (Mandelbrot fractals app running). Play allows 2–8;
      add a couple more (e.g. an agent task in the Workspace, Settings) before
      submission. Captured from the Pixel_5_API_30 arm64 emulator running the
      debug APK.
- [ ] **DECISION: bump `versionName`** off the dev tag `0.1.0-phase1c` to a
      store-appropriate string (e.g. `0.1.0`). `versionCode` stays an integer
      you increment each upload.
- [ ] **YOU: create the app in Play Console**, pick category (Tools), complete
      Data Safety form (guidance in `listing.md`), content rating (IARC
      questionnaire), target audience, and enter privacy/support URLs.
- [ ] **First upload to the internal testing track**, then promote to
      closed/production after validation.
- [ ] **Optional: support page hosted** (`../SUPPORT.md`) and a Play service
      account JSON if you want automated AAB uploads from CI.
- [x] **CI release pipeline** — `.github/workflows/android-release.yml`
      builds a signed AAB (arm64-v8a, `--gui sdl3`) and uploads it to the
      Play internal track on an `android-v*` tag. Consumes these repo
      secrets (the keystore as base64, the rest 1:1 with the
      `INFERNODE_UPLOAD_*` env the gradle reads):
        - `INFERNODE_UPLOAD_KEYSTORE_BASE64`  (`base64 -w0 infernode-upload.jks`)
        - `INFERNODE_UPLOAD_KEYSTORE_PASSWORD`
        - `INFERNODE_UPLOAD_KEY_ALIAS`        (optional; defaults to `upload`)
        - `INFERNODE_UPLOAD_KEY_PASSWORD`
        - `PLAY_SERVICE_ACCOUNT_JSON`         (Play Console service account,
          "Release apps to testing tracks")
      versionCode is the repo commit count (always climbs; the store is at
      3). First upload still needs the manual one below so the track exists.

## Build command (once native libs + assets are staged)

```
cd android-app
./gradlew bundleRelease     # → app/build/outputs/bundle/release/app-release.aab
```

The native `libemu.so`/`libSDL3.so` and the `assets/inferno-root/` tree are
produced by the existing `build-android-apk.sh` flow before Gradle runs — same
prerequisite as the debug APK.
