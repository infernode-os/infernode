package io.infernode

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * The phone's location for `#g` (emu/port/devlocation.c), through
 * emu/Android/locationbridge.c.
 *
 * The device calls [start] when the first reader opens `#g/nmea` and
 * [stop] when the last closes, so the receiver runs only while
 * something (gpsfs) listens. Both are called on an attached Inferno
 * kproc thread with a small stack: they only post to the main looper,
 * where LocationManager wants its calls, and return.
 *
 * Each position goes to the device as numbers through [nativeFix]; the
 * device writes it as NMEA. State goes through [nativeState]: `waiting`
 * once updates are asked for, `denied` without the location
 * permission, `off` with location services disabled, `ok` arriving with
 * the first fix (the device sets that itself).
 *
 * Altitude: Location.getAltitude is above the WGS84 ellipsoid, but NMEA
 * (and gpsfs's `alt`) is above mean sea level, which can differ by tens
 * of metres; only the platform's MSL altitude (Android 14+) is given,
 * and none on older releases rather than a wrong one.
 *
 * The provider is FUSED (Android 12+: GNSS, Wi-Fi and cells together),
 * else GPS. One provider only: two would interleave fixes of different
 * accuracy into one track.
 */
object InfernodeLocationBridge {
    private const val TAG = "InfernodeLocationBridge"
    private const val INTERVAL_MS = 1000L

    @Volatile
    private var appContext: Context? = null
    private var listening: LocationListener? = null

    @JvmStatic
    fun attach(ctx: Context) {
        appContext = ctx.applicationContext
    }

    /** 0 once updates are asked for (asynchronously), -1 with no service. */
    @JvmStatic
    fun start(): Int {
        val ctx = appContext ?: return -1
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return -1
        Handler(Looper.getMainLooper()).post { begin(ctx, lm) }
        return 0
    }

    @JvmStatic
    fun stop() {
        val ctx = appContext ?: return
        val lm = ctx.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
        Handler(Looper.getMainLooper()).post {
            listening?.let { lm.removeUpdates(it) }
            listening = null
        }
    }

    @SuppressLint("MissingPermission")  // checked just before
    private fun begin(ctx: Context, lm: LocationManager) {
        if (listening != null) return
        val fine = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
        val coarse = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_COARSE_LOCATION)
        if (fine != PackageManager.PERMISSION_GRANTED && coarse != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "no location permission")
            nativeState("denied")
            return
        }
        val provider = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            lm.allProviders.contains(LocationManager.FUSED_PROVIDER)
        ) LocationManager.FUSED_PROVIDER else LocationManager.GPS_PROVIDER
        val l = object : LocationListener {
            override fun onLocationChanged(loc: Location) = post(loc)
            override fun onProviderEnabled(p: String) = nativeState("waiting")
            override fun onProviderDisabled(p: String) = nativeState("off")
            @Deprecated("still called below Android 10")
            override fun onStatusChanged(p: String?, status: Int, extras: Bundle?) {}
        }
        try {
            lm.requestLocationUpdates(provider, INTERVAL_MS, 0f, l, Looper.getMainLooper())
        } catch (t: Throwable) {
            Log.w(TAG, "requestLocationUpdates($provider): ${t.message}")
            nativeState("unavailable")
            return
        }
        listening = l
        nativeState(if (lm.isProviderEnabled(provider)) "waiting" else "off")
        Log.i(TAG, "location updates from $provider")
    }

    private fun post(loc: Location) {
        var hasAlt = false
        var alt = 0.0
        var vacc = -1.0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && loc.hasMslAltitude()) {
            hasAlt = true
            alt = loc.mslAltitudeMeters
            if (loc.hasMslAltitudeAccuracy()) vacc = loc.mslAltitudeAccuracyMeters.toDouble()
        }
        try {
            nativeFix(
                loc.latitude, loc.longitude,
                hasAlt, alt,
                loc.hasSpeed(), loc.speed.toDouble(),
                loc.hasBearing(), loc.bearing.toDouble(),
                if (loc.hasAccuracy()) loc.accuracy.toDouble() else -1.0,
                vacc,
                loc.time,
            )
        } catch (ule: UnsatisfiedLinkError) {
            Log.w(TAG, "drop: nativeFix not linked")
        }
    }

    @JvmStatic
    external fun nativeFix(
        lat: Double, lon: Double,
        hasAlt: Boolean, alt: Double,
        hasSpeed: Boolean, speed: Double,
        hasCourse: Boolean, course: Double,
        hacc: Double, vacc: Double, utcms: Long,
    )

    @JvmStatic
    external fun nativeState(state: String)
}
