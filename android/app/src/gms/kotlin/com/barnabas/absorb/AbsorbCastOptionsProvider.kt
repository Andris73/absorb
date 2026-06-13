package com.barnabas.absorb

import android.content.Context
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.CastMediaOptions
import com.google.android.gms.cast.framework.media.NotificationOptions
import com.felnanuke.google_cast.GoogleCastOptionsProvider

/**
 * Wraps the flutter_chrome_cast plugin's OptionsProvider and adds
 * NotificationOptions so the Cast SDK shows its default media notification
 * with play/pause controls during casting.
 */
class AbsorbCastOptionsProvider : OptionsProvider {
    private val delegate = GoogleCastOptionsProvider()

    override fun getCastOptions(context: Context): CastOptions {
        val base = delegate.getCastOptions(context)
        val notificationOptions = NotificationOptions.Builder()
            .build()
        val mediaOptions = CastMediaOptions.Builder()
            .setNotificationOptions(notificationOptions)
            .build()
        return CastOptions.Builder()
            .setReceiverApplicationId(base.receiverApplicationId)
            .setLaunchOptions(base.launchOptions)
            .setResumeSavedSession(true)
            .setEnableReconnectionService(true)
            .setCastMediaOptions(mediaOptions)
            .build()
    }

    override fun getAdditionalSessionProviders(context: Context): MutableList<SessionProvider>? {
        return delegate.getAdditionalSessionProviders(context)
    }
}
