package com.barnabas.absorb

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.KeyEvent
import android.view.View
import android.net.Uri
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
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

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        syncTicker(context)
    }

    override fun onDisabled(context: Context) {
        syncTicker(context)
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

        // Portrait-height (dp) gates for the panel rows, measured across
        // launchers whose row heights differ a lot. A 1-row-tall widget reports
        // ~102dp (One UI) to ~121dp (Pixel); 2 rows ~233-257; 3 rows ~363-393.
        // These sit safely between those bands so tiers match on both.
        private const val INFO_MIN_HEIGHT_DP = 175
        private const val CHAPTER_MIN_HEIGHT_DP = 310

        // Width gate for the elapsed/remaining clocks beside the progress bar.
        // Measured: 2 real cells report 171dp (Pixel) / 201dp (One UI), 3 cells
        // 266dp / 315dp - so 230 means "at least 3 cells wide" on both.
        private const val TIMES_MIN_WIDTH_DP = 230

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

        private fun fmtTime(ms: Long): String {
            val totalS = ms / 1000
            val h = totalS / 3600
            val m = (totalS % 3600) / 60
            val s = totalS % 60
            return if (h > 0) String.format("%d:%02d:%02d", h, m, s) else String.format("%d:%02d", m, s)
        }

        private data class ScopeTimes(val elapsedMs: Long, val remainingMs: Long, val fraction: Float)

        // Live position for the clocks and the bar. The app only pushes state
        // every couple of seconds (and much less often in the background), so
        // extrapolate from the last pushed position + timestamp + speed. In
        // chapter mode, resolve which chapter the extrapolated position falls
        // in from the stashed chapter list - that way the clock and bar roll
        // over to the next chapter on time even between pushes.
        private fun computeTimes(widgetData: SharedPreferences): ScopeTimes? {
            val baseMs = widgetData.getInt("widget_pos_abs_ms", -1)
            val totalMs = widgetData.getInt("widget_total_ms", 0)
            if (baseMs < 0 || totalMs <= 0) return null

            val speedX100 = widgetData.getInt("widget_speed_x100", 100).coerceAtLeast(1)
            var absMs = baseMs.toLong()
            if (widgetData.getBoolean("widget_is_playing", false)) {
                val atS = widgetData.getInt("widget_pos_at_s", 0)
                if (atS > 0) {
                    val realMs = System.currentTimeMillis() - atS * 1000L
                    if (realMs > 0) absMs += realMs * speedX100 / 100
                }
            }
            absMs = absMs.coerceIn(0L, totalMs.toLong())

            var scopeStart = 0L
            var scopeEnd = totalMs.toLong()
            if (widgetData.getBoolean("widget_chapter_mode", false)) {
                val json = widgetData.getString("np_chapters_json", null)
                if (!json.isNullOrEmpty()) {
                    try {
                        val arr = JSONArray(json)
                        for (i in 0 until arr.length()) {
                            val ch = arr.optJSONObject(i) ?: continue
                            val startMs = (ch.optDouble("start", -1.0) * 1000).toLong()
                            val endMs = (ch.optDouble("end", -1.0) * 1000).toLong()
                            if (startMs < 0 || endMs <= startMs) continue
                            if (absMs >= startMs && (absMs < endMs || i == arr.length() - 1)) {
                                scopeStart = startMs
                                scopeEnd = endMs
                                break
                            }
                        }
                    } catch (_: Exception) {
                    }
                }
            }

            val scopeLen = (scopeEnd - scopeStart).coerceAtLeast(1L)
            val elapsed = (absMs - scopeStart).coerceIn(0L, scopeLen)
            // Display listening time (content time / speed), matching the app
            // and the notification at non-1x speeds. It also makes the clock
            // advance one second per real second instead of jumping.
            return ScopeTimes(
                elapsed * 100 / speedX100,
                (scopeLen - elapsed) * 100 / speedX100,
                elapsed.toFloat() / scopeLen
            )
        }

        // Per-second clock. While playing and at least one widget shows the
        // panel, a Handler ticks once a second and pushes ONLY the two time
        // strings (plus an occasional bar refresh) via
        // partiallyUpdateAppWidget - the cover bitmap is never re-sent, so a
        // tick is a few bytes of IPC. Skips all work while the screen is off
        // and stops itself when playback stops. The process is alive whenever
        // this matters because playback holds a foreground service.
        private val tickHandler = Handler(Looper.getMainLooper())
        private var ticking = false
        private var tickCount = 0
        private var tickContext: Context? = null

        private val tickRunnable = object : Runnable {
            override fun run() {
                if (!ticking) return
                val ctx = tickContext ?: return
                try {
                    doTick(ctx)
                } catch (e: Exception) {
                    android.util.Log.e("NowPlayingWidgetTiny", "tick failed", e)
                }
                if (ticking) tickHandler.postDelayed(this, 1000L)
            }
        }

        private fun syncTicker(context: Context) {
            val app = context.applicationContext
            val widgetData = HomeWidgetPlugin.getData(app)
            var shouldTick = widgetData.getBoolean("widget_has_book", false) &&
                widgetData.getBoolean("widget_is_playing", false)
            if (shouldTick) {
                val mgr = AppWidgetManager.getInstance(app)
                val ids = mgr.getAppWidgetIds(ComponentName(app, NowPlayingWidgetTiny::class.java))
                shouldTick = ids.any { id ->
                    cellsFor(mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)) >= 2
                }
            }
            if (shouldTick && !ticking) {
                ticking = true
                tickCount = 0
                tickContext = app
                tickHandler.postDelayed(tickRunnable, 1000L)
            } else if (!shouldTick && ticking) {
                ticking = false
                tickContext = null
                tickHandler.removeCallbacks(tickRunnable)
            }
        }

        private fun doTick(context: Context) {
            tickCount++
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            if (!pm.isInteractive) return
            val widgetData = HomeWidgetPlugin.getData(context)
            if (!widgetData.getBoolean("widget_is_playing", false)) {
                syncTicker(context)
                return
            }
            val times = computeTimes(widgetData) ?: return
            val density = context.resources.displayMetrics.density
            val mgr = AppWidgetManager.getInstance(context)
            for (id in mgr.getAppWidgetIds(ComponentName(context, NowPlayingWidgetTiny::class.java))) {
                val widthDp = mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
                if (cellsFor(widthDp) < 2) continue
                val showTimes = widthDp >= TIMES_MIN_WIDTH_DP
                val refreshBar = tickCount % 10 == 0
                if (!showTimes && !refreshBar) continue
                val partial = RemoteViews(context.packageName, R.layout.now_playing_widget_tiny)
                if (showTimes) {
                    partial.setTextViewText(R.id.widget_time_elapsed, fmtTime(times.elapsedMs))
                    partial.setTextViewText(R.id.widget_time_remaining, "-" + fmtTime(times.remainingMs))
                }
                if (refreshBar) {
                    partial.setImageViewBitmap(
                        R.id.widget_progress,
                        drawProgressBar(barWidthPx(widthDp, showTimes, density), (12 * density).toInt(), times.fraction, true, density)
                    )
                }
                mgr.partiallyUpdateAppWidget(id, partial)
            }
        }

        // The bar bitmap is stretched with fitXY, so this only needs to be
        // close: row padding eats ~36dp, the two clocks ~110dp when shown.
        private fun barWidthPx(widthDp: Int, showTimes: Boolean, density: Float): Int =
            ((widthDp - 36 - if (showTimes) 110 else 0).coerceAtLeast(40) * density).toInt()

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

            // Wide enough (2+ cells) for the transport row, and a session to control.
            val showPanel = hasBook && cellsFor(widthDp) >= 2
            // Reveal the info rows by how many dp of height the launcher actually
            // gives the widget, not by cell count: launcher row heights vary too
            // much (a 1-row widget reports ~102dp on One UI but ~121dp on Pixel),
            // and the old 70dp-cell formula miscounted the taller one as 2 rows.
            val showInfo = showPanel && heightDp >= INFO_MIN_HEIGHT_DP
            val showChapter = showPanel && heightDp >= CHAPTER_MIN_HEIGHT_DP

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

                // Transport + progress are in every panel size, including the
                // short buttons-only one (cover + squiggle + controls, like a
                // compact notification).
                views.setTextViewText(R.id.widget_skip_back_text, widgetData.getInt("widget_skip_back", 10).toString())
                views.setTextViewText(R.id.widget_skip_forward_text, widgetData.getInt("widget_skip_forward", 30).toString())
                views.setImageViewResource(R.id.widget_pp, playPauseIcon)

                val times = computeTimes(widgetData)
                val fraction = times?.fraction ?: (widgetData.getInt("widget_progress", 0) / 1000f)
                val showTimes = widthDp >= TIMES_MIN_WIDTH_DP && times != null
                views.setImageViewBitmap(
                    R.id.widget_progress,
                    drawProgressBar(barWidthPx(widthDp, showTimes, density), (12 * density).toInt(), fraction, isPlaying, density)
                )
                views.setViewVisibility(R.id.widget_progress_row, View.VISIBLE)

                // Elapsed / remaining clocks flank the bar on wide widgets;
                // the per-second ticker keeps them live while playing.
                if (showTimes) {
                    views.setTextViewText(R.id.widget_time_elapsed, fmtTime(times!!.elapsedMs))
                    views.setTextViewText(R.id.widget_time_remaining, "-" + fmtTime(times.remainingMs))
                    views.setViewVisibility(R.id.widget_time_elapsed, View.VISIBLE)
                    views.setViewVisibility(R.id.widget_time_remaining, View.VISIBLE)
                } else {
                    views.setViewVisibility(R.id.widget_time_elapsed, View.GONE)
                    views.setViewVisibility(R.id.widget_time_remaining, View.GONE)
                }

                // Title / author only once there's vertical room for them.
                if (showInfo) {
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
            syncTicker(context)
        }
    }
}
