package com.barnabas.absorb

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import android.view.KeyEvent
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONObject

/**
 * Phone-side receiver for playback commands from the AbsorbWear watch.
 *
 * Two flavours:
 *  - play-pause / skip-back / skip-forward: forwarded to the active
 *    MediaSession as a MEDIA_BUTTON broadcast. Same code path Bluetooth
 *    headphones and the NowPlayingWidget already use, so we get
 *    user-configured skip durations for free.
 *  - play-item: launches MainActivity with a URI the home_widget plugin
 *    can route. Flutter's HomeWidgetService picks it up and calls
 *    AudioPlayerService.playItem unconditionally (replacing any current
 *    session).
 */
class WearPlayerCommandListenerService : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            "/absorb/player/cmd/play-pause" -> dispatchMediaButton(KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE)
            "/absorb/player/cmd/skip-back" -> dispatchMediaButton(KeyEvent.KEYCODE_MEDIA_REWIND)
            "/absorb/player/cmd/skip-forward" -> dispatchMediaButton(KeyEvent.KEYCODE_MEDIA_FAST_FORWARD)
            "/absorb/player/cmd/play-item" -> handlePlayItem(event.data)
            else -> super.onMessageReceived(event)
        }
    }

    private fun dispatchMediaButton(keyCode: Int) {
        Log.i(TAG, "Watch -> MediaButton keyCode=$keyCode")
        val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
            component = ComponentName(
                applicationContext,
                "com.ryanheise.audioservice.MediaButtonReceiver",
            )
            putExtra(
                Intent.EXTRA_KEY_EVENT,
                KeyEvent(KeyEvent.ACTION_DOWN, keyCode),
            )
        }
        applicationContext.sendBroadcast(intent)
    }

    private fun handlePlayItem(data: ByteArray) {
        val payload = try {
            JSONObject(data.decodeToString())
        } catch (e: Exception) {
            Log.w(TAG, "play-item payload not JSON", e); return
        }
        val itemId = payload.optString("itemId").ifBlank { null }
        if (itemId == null) {
            Log.w(TAG, "play-item missing itemId"); return
        }
        val episodeId = payload.optString("episodeId").ifBlank { null }

        // Build a URI the home_widget plugin already knows how to route
        // — it captures intents whose action is HOME_WIDGET_CLICK and
        // posts the data URI onto HomeWidget.widgetClicked. The Dart
        // side adds a /play_item case that parses these query params.
        val builder = Uri.Builder()
            .scheme("absorb")
            .authority("widget")
            .appendPath("play_item")
            .appendQueryParameter("itemId", itemId)
        if (episodeId != null) builder.appendQueryParameter("episodeId", episodeId)
        val uri = builder.build()

        val intent = Intent(applicationContext, MainActivity::class.java).apply {
            action = HOME_WIDGET_CLICK
            this.data = uri
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        Log.i(TAG, "Watch -> play-item uri=$uri")
        try {
            applicationContext.startActivity(intent)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to launch MainActivity for play-item", e)
        }
    }

    companion object {
        private const val TAG = "WearPlayerBridge"
        // Intent action the home_widget plugin filters for.
        private const val HOME_WIDGET_CLICK = "es.antonborri.home_widget.action.LAUNCH"
    }
}
