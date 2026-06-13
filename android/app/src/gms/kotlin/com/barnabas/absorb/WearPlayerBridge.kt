package com.barnabas.absorb

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import org.json.JSONObject

/**
 * Pushes the current ABS playback snapshot to the paired Wear OS app
 * (AbsorbWear) so the watch can render "Now Playing" without making any
 * direct calls to the server.
 *
 * Keep the field set in sync with `com.barnabas.absorb.wear.player.PlayerState`
 * on the watch side. Bump the path version (`v1` → `v2`) when the shape
 * changes — DataItems are persistent and stale watches will still see the
 * last published payload until you republish.
 */
object WearPlayerBridge {
    private const val TAG = "WearPlayerBridge"

    const val STATE_PATH = "/absorb/player/state/v1"

    private const val KEY_PAYLOAD = "payload"
    private const val KEY_ISSUED_AT = "issuedAt"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Push the current playback snapshot. Call from the same throttle
     *  loop that updates the home widget — anything finer-grained than
     *  ~2s is wasted bandwidth. */
    fun publish(
        context: Context,
        hasBook: Boolean,
        itemId: String?,
        title: String?,
        author: String?,
        chapter: String?,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long,
        speed: Float,
        skipBackSec: Int,
        skipForwardSec: Int,
    ) {
        scope.launch {
            try {
                val now = System.currentTimeMillis()
                val payload = JSONObject().apply {
                    put("hasBook", hasBook)
                    put("itemId", itemId ?: JSONObject.NULL)
                    put("title", title ?: JSONObject.NULL)
                    put("author", author ?: JSONObject.NULL)
                    put("chapter", chapter ?: JSONObject.NULL)
                    put("isPlaying", isPlaying)
                    put("positionMs", positionMs)
                    put("durationMs", durationMs)
                    put("speed", speed.toDouble())
                    put("skipBackSec", skipBackSec)
                    put("skipForwardSec", skipForwardSec)
                    put("issuedAt", now)
                }.toString()

                val request = PutDataMapRequest.create(STATE_PATH).apply {
                    // Both fields contribute to the diff hash — the timestamp
                    // alone keeps republishes of identical metadata flowing
                    // (so position-tick updates still propagate).
                    dataMap.putByteArray(KEY_PAYLOAD, payload.toByteArray(Charsets.UTF_8))
                    dataMap.putLong(KEY_ISSUED_AT, now)
                }.asPutDataRequest().setUrgent()

                Wearable.getDataClient(context.applicationContext).putDataItem(request).await()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to publish player state", e)
            }
        }
    }
}
