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
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import java.io.File

// Adaptive now-playing widget. At 1x1 it's just the cover with a centered
// play/pause tap target. Resize it larger and a notification-style player panel
// (title / author / chapter / progress / transport) fades in over the bottom of
// the cover; rows appear as the widget grows enough to hold them.
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

    // Re-render when the user resizes so the player panel appears/disappears
    // and the cover is decoded at a resolution that fits the new size.
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        try {
            updateWidget(context, appWidgetManager, appWidgetId)
        } catch (e: Exception) {
            android.util.Log.e("NowPlayingWidgetTiny", "resize update failed", e)
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

        // Android's own cell-size formula: 70dp per cell, 30dp inter-cell gap.
        private fun cellsFor(dp: Int): Int = if (dp <= 0) 1 else (dp + 30) / 70

        private fun mediaButtonPendingIntent(
            context: Context,
            keyCode: Int,
            requestCode: Int
        ): PendingIntent {
            val intent = Intent(Intent.ACTION_MEDIA_BUTTON).apply {
                component = ComponentName(context, "com.ryanheise.audioservice.MediaButtonReceiver")
                putExtra(Intent.EXTRA_KEY_EVENT, KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
            }
            return PendingIntent.getBroadcast(
                context, requestCode, intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        // Active-session play/pause: flip the icon instantly via our receiver,
        // which then forwards to the MediaSession.
        private fun togglePendingIntent(context: Context): PendingIntent {
            val toggleIntent = Intent(context, NowPlayingWidgetTiny::class.java).apply {
                action = ACTION_TOGGLE_PLAYBACK
            }
            return PendingIntent.getBroadcast(
                context, 1, toggleIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        }

        private fun openAppPendingIntent(context: Context): PendingIntent =
            HomeWidgetLaunchIntent.getActivity(
                context, MainActivity::class.java, Uri.parse("absorb://widget/open")
            )

        // Decode the cover no larger than the widget needs, then mask rounded
        // corners. targetPx keeps a big cover crisp without decoding a huge
        // bitmap that RemoteViews would refuse to serialise.
        private fun loadCover(path: String, targetPx: Int, radiusDp: Float, density: Float): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            val srcEdge = minOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (srcEdge / (sample * 2) >= targetPx) sample *= 2

            val opts = BitmapFactory.Options().apply { inSampleSize = sample }
            val bitmap = BitmapFactory.decodeFile(path, opts) ?: return null

            // Scale the corner radius to the decoded bitmap so it looks right
            // after the ImageView's centerCrop maps it onto the tile.
            val displayPx = targetPx.toFloat().coerceAtLeast(1f)
            val scale = minOf(bitmap.width, bitmap.height).toFloat() / displayPx
            val radiusPx = radiusDp * density * scale
            val output = Bitmap.createBitmap(bitmap.width, bitmap.height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(output)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            canvas.drawRoundRect(RectF(0f, 0f, bitmap.width.toFloat(), bitmap.height.toFloat()), radiusPx, radiusPx, paint)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
            canvas.drawBitmap(bitmap, 0f, 0f, paint)
            // Recycle only the source: RemoteViews serialises `output` later in
            // updateAppWidget, so recycling it here crashes the app.
            bitmap.recycle()
            return output
        }

        // Progress bar drawn by hand so we can give it the Android-Auto squiggle:
        // the played portion waves while playing and flattens when paused, the
        // rest stays a dim straight track. The wave is static, not animated.
        private fun drawProgressBar(
            widthPx: Int,
            heightPx: Int,
            fraction: Float,
            playing: Boolean,
            density: Float
        ): Bitmap {
            val w = widthPx.coerceAtLeast(1)
            val h = heightPx.coerceAtLeast(1)
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bmp)
            val centerY = h / 2f
            val stroke = 2.5f * density
            val inset = stroke
            val progressX = (w * fraction.coerceIn(0f, 1f)).coerceIn(inset, w - inset)

            val trackPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0x66FFFFFF
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
            }
            val activePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = 0xFFFFFFFF.toInt()
                style = Paint.Style.STROKE
                strokeWidth = stroke
                strokeCap = Paint.Cap.ROUND
            }

            // Remaining track: straight, dim.
            canvas.drawLine(progressX, centerY, w - inset, centerY, trackPaint)

            // Played portion.
            if (playing) {
                val amplitude = 3f * density
                val wavelength = 24f * density
                val path = Path()
                path.moveTo(inset, centerY)
                var x = inset
                while (x < progressX) {
                    val y = centerY + amplitude * Math.sin((x / wavelength) * 2.0 * Math.PI).toFloat()
                    path.lineTo(x, y)
                    x += 1.5f
                }
                path.lineTo(progressX, centerY + amplitude * Math.sin((progressX / wavelength) * 2.0 * Math.PI).toFloat())
                canvas.drawPath(path, activePaint)
            } else {
                canvas.drawLine(inset, centerY, progressX, centerY, activePaint)
            }

            return bmp
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

            // Current widget size. Portrait reports width via MIN_WIDTH and
            // height via MAX_HEIGHT; use the largest edge to size the cover.
            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            val widthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 40)
            val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 40)
            val density = context.resources.displayMetrics.density
            val targetPx = (maxOf(widthDp, heightDp, 80) * density).toInt()

            val cellsW = cellsFor(widthDp)
            val cellsH = cellsFor(heightDp)
            // Wide enough (2+ cells) for the transport row, and a session to control.
            val showPanel = hasBook && cellsW >= 2
            // Tall enough to also carry the title/author, then chapter.
            val showInfo = showPanel && cellsH >= 2
            val showChapter = showPanel && cellsH >= 3

            // Cover art (rounded corners)
            var cover: Bitmap? = null
            if (coverPath != null) {
                val file = File(coverPath)
                if (file.exists()) {
                    cover = loadCover(file.absolutePath, targetPx, 16f, density)
                }
            }
            if (cover != null) {
                views.setImageViewBitmap(R.id.widget_cover, cover)
            } else {
                views.setImageViewResource(R.id.widget_cover, R.mipmap.ic_launcher)
            }

            val playPauseIcon = if (isPlaying) R.drawable.ic_widget_pause_dark else R.drawable.ic_widget_play_dark

            if (showPanel) {
                // Larger size: hide the centered dot, show the player panel.
                views.setViewVisibility(R.id.widget_play_pause, View.GONE)
                views.setViewVisibility(R.id.widget_panel, View.VISIBLE)

                // When it's only tall enough for the button row, keep the panel
                // tight; give it breathing room once text/progress appear.
                val padTop = ((if (showInfo) 22 else 8) * density).toInt()
                val padBottom = ((if (showInfo) 12 else 8) * density).toInt()
                views.setViewPadding(R.id.widget_panel, 0, padTop, 0, padBottom)

                // Transport is always in the panel.
                views.setTextViewText(R.id.widget_skip_back_text, widgetData.getInt("widget_skip_back", 10).toString())
                views.setTextViewText(R.id.widget_skip_forward_text, widgetData.getInt("widget_skip_forward", 30).toString())
                views.setImageViewResource(R.id.widget_pp, playPauseIcon)

                // Progress + title/author appear once there's vertical room;
                // at 1 cell tall it's just the buttons.
                if (showInfo) {
                    val progress = widgetData.getInt("widget_progress", 0)
                    val barW = ((widthDp - 36).coerceAtLeast(40) * density).toInt()
                    val barH = (12 * density).toInt()
                    views.setImageViewBitmap(
                        R.id.widget_progress,
                        drawProgressBar(barW, barH, progress / 1000f, isPlaying, density)
                    )
                    views.setViewVisibility(R.id.widget_progress, View.VISIBLE)

                    val title = widgetData.getString("widget_title", null)
                    val author = widgetData.getString("widget_author", null)
                    views.setTextViewText(R.id.widget_title, if (title.isNullOrEmpty()) "Absorb" else title)
                    views.setViewVisibility(R.id.widget_title, View.VISIBLE)
                    if (author.isNullOrEmpty()) {
                        views.setViewVisibility(R.id.widget_author, View.GONE)
                    } else {
                        views.setTextViewText(R.id.widget_author, author)
                        views.setViewVisibility(R.id.widget_author, View.VISIBLE)
                    }
                } else {
                    views.setViewVisibility(R.id.widget_progress, View.GONE)
                    views.setViewVisibility(R.id.widget_title, View.GONE)
                    views.setViewVisibility(R.id.widget_author, View.GONE)
                }

                val chapter = widgetData.getString("widget_chapter", null)
                if (showChapter && !chapter.isNullOrEmpty()) {
                    views.setTextViewText(R.id.widget_chapter, chapter)
                    views.setViewVisibility(R.id.widget_chapter, View.VISIBLE)
                } else {
                    views.setViewVisibility(R.id.widget_chapter, View.GONE)
                }

                views.setOnClickPendingIntent(
                    R.id.widget_skip_back,
                    mediaButtonPendingIntent(context, KeyEvent.KEYCODE_MEDIA_REWIND, 22)
                )
                views.setOnClickPendingIntent(R.id.widget_pp, togglePendingIntent(context))
                views.setOnClickPendingIntent(
                    R.id.widget_skip_forward,
                    mediaButtonPendingIntent(context, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD, 23)
                )

                // Tapping the cover itself opens the app (buttons handle playback).
                views.setOnClickPendingIntent(R.id.widget_root, openAppPendingIntent(context))
            } else {
                // 1x1: centered indicator, whole tile toggles play/pause.
                views.setViewVisibility(R.id.widget_panel, View.GONE)
                if (hasBook) {
                    views.setViewVisibility(R.id.widget_play_pause, View.VISIBLE)
                    views.setImageViewResource(R.id.widget_play_pause, playPauseIcon)
                } else {
                    views.setViewVisibility(R.id.widget_play_pause, View.GONE)
                }

                val tapIntent = if (hasBook) {
                    togglePendingIntent(context)
                } else {
                    HomeWidgetLaunchIntent.getActivity(
                        context, MainActivity::class.java, Uri.parse("absorb://widget/play_pause")
                    )
                }
                views.setOnClickPendingIntent(R.id.widget_root, tapIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
