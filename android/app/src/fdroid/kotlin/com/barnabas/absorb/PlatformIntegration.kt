package com.barnabas.absorb

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine

/**
 * F-Droid (GMS-free) build: the Chromecast and Wear OS Data Layer channels are
 * absent because they depend on Google Play Services. This no-op twin keeps
 * MainActivity flavor-agnostic.
 *
 * The Dart side never invokes these channels in the fdroid flavor (the cast UI
 * is stubbed out), and if it did, the resulting MissingPluginException is
 * already caught by the existing try/catch in the Dart services.
 */
object PlatformIntegration {
    fun registerChannels(activity: Activity, flutterEngine: FlutterEngine) {
        // no-op: cast + wear bridges require Google Play Services
    }
}
