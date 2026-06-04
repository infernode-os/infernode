package io.infernode

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.widget.FrameLayout
import android.widget.ProgressBar

/**
 * Launcher splash. Extracts the ~48 MB Inferno asset tree on a BACKGROUND
 * thread, then hands off to [InfernodeSDLActivity].
 *
 * Why this exists: extraction used to run synchronously in
 * InfernodeSDLActivity.onCreate, blocking the main thread (~2 s on an A55,
 * longer on slower devices and on every post-update re-extraction) — a latent
 * ANR. emu's `-r` argv references the extracted tree, and SDL_main starts
 * inside SDLActivity's super.onCreate() on the main thread, so the copy can't
 * simply be backgrounded *inside* that activity. Doing it here, before the SDL
 * activity is created, keeps the main thread free while the tree is built.
 *
 * The SDL activity stays exported and still calls [AssetExtractor] itself (a
 * fast no-op once the marker exists), so `am start` of it directly — harness,
 * the CI smoke test — remains correct.
 */
class InfernodeSplashActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Minimal black loading screen (Lucifer's brimstone). The activity's
        // theme is Theme.Black.NoTitleBar (manifest) so the window is black
        // immediately — no white flash before this content draws.
        val root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        root.addView(
            ProgressBar(this),
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER,
            ),
        )
        setContentView(root)

        val activity = this
        Thread {
            val t0 = System.currentTimeMillis()
            try {
                AssetExtractor.extractInfernoRootIfNeeded(activity)
            } catch (e: Exception) {
                Log.e(TAG, "asset extraction failed", e)
            }
            Log.i(TAG, "asset extraction took ${System.currentTimeMillis() - t0} ms")
            activity.runOnUiThread {
                if (!activity.isFinishing) {
                    activity.startActivity(Intent(activity, InfernodeSDLActivity::class.java))
                    activity.finish()
                }
            }
        }.start()
    }

    companion object {
        private const val TAG = "InfernodeSplash"
    }
}
