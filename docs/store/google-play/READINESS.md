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
- [ ] **YOU: generate the upload keystore** (see `keystore.properties.example`)
      and create `android-app/keystore.properties`.
- [ ] **YOU: Play Console account confirmed**, $25 registration done.
- [ ] **Privacy policy hosted at a public URL** — Play requires the URL on the
      listing. (GitHub Pages off this repo is the zero-cost route.)

## Remaining before review submission

- [ ] **Screenshots** — 2–8 phone screenshots (min 320 px short side). Needs the
      app running on a device/emulator; capture Lucifer + the agent UI.
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
- [ ] **Optional: CI** — `.github/workflows/android-apk.yml` builds a *debug*
      APK only. A signed-`bundleRelease` job (consuming the `INFERNODE_UPLOAD_*`
      secrets) would close the release loop; not required for a manual first
      submission.

## Build command (once native libs + assets are staged)

```
cd android-app
./gradlew bundleRelease     # → app/build/outputs/bundle/release/app-release.aab
```

The native `libemu.so`/`libSDL3.so` and the `assets/inferno-root/` tree are
produced by the existing `build-android-apk.sh` flow before Gradle runs — same
prerequisite as the debug APK.
