package com.barnabas.absorb

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.view.KeyEvent
import android.view.View
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File

// 1x1 widget: just the cover art. Tapping anywhere toggles play/pause.
class NowPlayingWidgetTiny : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (appWidgetId in appWidgetIds) {
            // Never let a widget render failure crash the whole app.
            try {
                updateWidget(context, appWidgetManager, appWidgetId)
            } catch (e: Exception) {
                android.util.Log.e("NowPlayingWidgetTiny", "updateWidget failed", e)
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_TOGGLE_PLAYBACK) {
            // Optimistic UI: flip the icon immediately, then send the real media button.
            val widgetData = HomeWidgetPlugin.getData(context)
            val wasPlaying = widgetData.getBoolean("widget_is_playing", false)
            widgetData.edit().putBoolean("widget_is_playing", !wasPlaying).apply()

            val mgr = AppWidgetManager.getInstance(context)
            for (id in mgr.getAppWidgetIds(ComponentName(context, NowPlayingWidgetTiny::class.java))) {
                updateWidget(context, mgr, id)
            }

            val mediaIntent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
            }
            context.sendBroadcast(mediaIntent)
            return
        }
        super.onReceive(context, intent)
    }

    companion object {
        const val ACTION_TOGGLE_PLAYBACK = "com.barnabas.absorb.ACTION_TOGGLE_PLAYBACK_TINY"

        private fun roundBitmap(bitmap: Bitmap, radiusDp: Float, context: Context): Bitmap {
            val density = context.resources.displayMetrics.density
            // ~80dp target tile; scale the radius to the source bitmap so corners
            // look right after centerCrop.
            val displayPx = 80f * density
            val scale = minOf(bitmap.width, bitmap.height).toFloat() / displayPx
            val radiusPx = radiusDp * density * scale
            val output = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val rect = RectF(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat())
            canvas.drawRoundRect(rect, radiusPx, radiusPx, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(bitmap, 0f, 0f, paint)
            return output
        }

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int
        ) {
            val widgetData = HomeWidgetPlugin.getData(context)
            val views = RemoteViews(context.packageName, R.layout.now_playing_widget_tiny)

            val hasBook = widgetData.getBoolean("widget_has_book", false)
            val isPlaying = widgetData.getBoolean("widget_is_playing", false)
            val coverPath = widgetData.getString("widget_cover_path", null)

            // Cover art (rounded corners)
            var setCover = false
            if (coverPath != null) {
                val file = File(coverPath)
                if (file.exists()) {
                    val options = BitmapFactory.Options().apply { inSampleSize = 2 }
                    val bitmap = BitmapFactory.decodeFile(file.absolutePath, options)
                    if (bitmap != null) {
                        val rounded = roundBitmap(bitmap, 16f, context)
                        views.setImageViewBitmap(R.id.widget_cover, rounded)
                        // Recycle only the source: RemoteViews serialises `rounded`
                        // later in updateAppWidget, so recycling it here crashes the app.
                        bitmap.recycle()
                        setCover = true
                    }
                }
            }
            if (!setCover) views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)

            // Play/pause indicator - only when there's a session to control.
            if (hasBook) {
                views.setViewVisibility(R.id.widget_play_pause, View.VISIBLE)
                views.setImageViewResource(
                    R.id.widget_play_pause,
                    if (isPlaying) R.drawable.ic_widget_pause_dark else R.drawable.ic_widget_play_dark
                )
            } else {
                views.setViewVisibility(R.id.widget_play_pause, View.GONE)
            }

            // Tap anywhere on the tile: toggle if there's a session, else open the app.
            val tapIntent = if (hasBook) {
                val toggleIntent = Intent(context, NowPlayingWidgetTiny::class.java).apply {
                    action = ACTION_TOGGLE_PLAYBACK
                }
                PendingIntent.getBroadcast(
                    context, 1, toggleIntent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            } else {
                HomeWidgetLaunchIntent.getActivity(
                    context,
                    MainActivity::class.java,
                    Uri.parse("absorb://widget/play_pause")
                )
            }
            views.setOnClickPendingIntent(R.id.widget_root, tapIntent)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
