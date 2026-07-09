package com.barnabas.absorb

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.widget.RemoteViews
import com.ryanheise.audioservice.AudioServicePlugin
import es.antonborri.home_widget.HomeWidgetPlugin
import io.flutter.embedding.engine.FlutterEngineCache
import org.json.JSONArray

// Shared live-clock machinery for the now-playing widgets: the squiggle
// progress bar bitmap, elapsed/remaining formatting, position extrapolation
// between the app's throttled data pushes, and a per-second ticker that
// patches only the clock text (plus an occasional bar refresh) via
// partiallyUpdateAppWidget - the cover bitmap is never re-sent, so a tick is
// a few bytes of IPC. Skips all work while the screen is off and stops itself
// when playback stops. The process is alive whenever this matters because
// playback holds a foreground service.
internal object WidgetClock {
    // Android's own cell-size formula: 70dp per cell, 30dp inter-cell gap.
    fun cellsFor(dp: Int): Int = if (dp <= 0) 1 else (dp + 30) / 70

    // widget_has_book / widget_title are stashed prefs that outlive the app
    // process, so they still read true after a swipe-close. Routing a tap
    // through the MediaSession broadcast in that state is a dead end -
    // AudioService.onCreate only adopts a cached engine, never creates one,
    // so a truly dead process can't pick the button press up at all. Gate on
    // whether an engine is actually cached to tell "session still alive" from
    // "just stale prefs" and fall back to a normal cold-start app launch.
    fun isEngineAlive(): Boolean =
        FlutterEngineCache.getInstance().get(AudioServicePlugin.getFlutterEngineId()) != null

    // Width gate for the tiny widget's clocks beside the progress bar.
    // Measured: 2 real cells report 171dp (Pixel) / 201dp (One UI), 3 cells
    // 266dp / 315dp - so 230 means "at least 3 cells wide" on both.
    const val TINY_TIMES_MIN_WIDTH_DP = 230

    fun fmtTime(ms: Long): String {
        val totalS = ms / 1000
        val h = totalS / 3600
        val m = (totalS % 3600) / 60
        val s = totalS % 60
        return if (h > 0) String.format("%d:%02d:%02d", h, m, s) else String.format("%d:%02d", m, s)
    }

    data class ScopeTimes(val elapsedMs: Long, val remainingMs: Long, val fraction: Float)

    // Live position for the clocks and the bar. The app only pushes state
    // every couple of seconds (and much less often in the background), so
    // extrapolate from the last pushed position + timestamp + speed. In
    // chapter mode, resolve which chapter the extrapolated position falls in
    // from the stashed chapter list - that way the clock and bar roll over to
    // the next chapter on time even between pushes. Times are displayed as
    // listening time (content time / speed), matching the app and the
    // notification at non-1x speeds; it also makes the clock advance one
    // second per real second instead of jumping.
    fun computeTimes(widgetData: SharedPreferences): ScopeTimes? {
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
        return ScopeTimes(
            elapsed * 100 / speedX100,
            (scopeLen - elapsed) * 100 / speedX100,
            elapsed.toFloat() / scopeLen
        )
    }

    // Progress bar drawn by hand so we can give it the Android-Auto squiggle:
    // the played portion waves while playing and flattens when paused, the
    // rest stays a dim straight track. The wave is static, not animated.
    fun drawProgressBar(
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

        canvas.drawLine(progressX, centerY, w - inset, centerY, trackPaint)

        if (playing) {
            // Capped so the wave fits thinner bars (the compact strip).
            val amplitude = minOf(1.8f * density, (h - stroke * 2) / 2f).coerceAtLeast(0.75f)
            val wavelength = 36f * density
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

    // Bar bitmap width estimates per widget. The bars are stretched with
    // fitXY, so these only need to be close: the tiny widget's row padding
    // eats ~36dp and its two clocks ~110dp; the big widget loses its cover
    // and text padding; the compact its cover.
    fun tinyBarWidthPx(widthDp: Int, showTimes: Boolean, density: Float): Int =
        ((widthDp - 36 - if (showTimes) 110 else 0).coerceAtLeast(40) * density).toInt()

    fun bigBarWidthPx(widthDp: Int, density: Float): Int =
        ((widthDp - 160).coerceAtLeast(60) * density).toInt()

    fun compactBarWidthPx(widthDp: Int, density: Float): Int =
        ((widthDp - 110).coerceAtLeast(60) * density).toInt()

    // ── Per-second ticker ──

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
                android.util.Log.e("WidgetClock", "tick failed", e)
            }
            if (ticking) tickHandler.postDelayed(this, 1000L)
        }
    }

    private fun ids(context: Context, mgr: AppWidgetManager, cls: Class<*>): IntArray =
        mgr.getAppWidgetIds(ComponentName(context, cls))

    private fun minWidthDp(mgr: AppWidgetManager, id: Int): Int =
        mgr.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)

    fun syncTicker(context: Context) {
        val app = context.applicationContext
        val widgetData = HomeWidgetPlugin.getData(app)
        val hasPlayableItem = widgetData.getBoolean("widget_has_book", false) ||
            !widgetData.getString("widget_title", null).isNullOrEmpty()
        var shouldTick = hasPlayableItem &&
            widgetData.getBoolean("widget_is_playing", false)
        if (shouldTick) {
            val mgr = AppWidgetManager.getInstance(app)
            shouldTick = ids(app, mgr, NowPlayingWidget::class.java).isNotEmpty() ||
                ids(app, mgr, NowPlayingWidgetCompact::class.java).isNotEmpty() ||
                ids(app, mgr, NowPlayingWidgetTiny::class.java).any { cellsFor(minWidthDp(mgr, it)) >= 2 }
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
        val refreshBar = tickCount % 10 == 0
        val elapsed = fmtTime(times.elapsedMs)
        val remaining = "-" + fmtTime(times.remainingMs)

        for (id in ids(context, mgr, NowPlayingWidgetTiny::class.java)) {
            val widthDp = minWidthDp(mgr, id)
            if (cellsFor(widthDp) < 2) continue
            val showTimes = widthDp >= TINY_TIMES_MIN_WIDTH_DP
            if (!showTimes && !refreshBar) continue
            val partial = RemoteViews(context.packageName, R.layout.now_playing_widget_tiny)
            if (showTimes) {
                partial.setTextViewText(R.id.widget_time_elapsed, elapsed)
                partial.setTextViewText(R.id.widget_time_remaining, remaining)
            }
            if (refreshBar) {
                partial.setImageViewBitmap(
                    R.id.widget_progress,
                    drawProgressBar(tinyBarWidthPx(widthDp, showTimes, density), (12 * density).toInt(), times.fraction, true, density)
                )
            }
            mgr.partiallyUpdateAppWidget(id, partial)
        }

        for (id in ids(context, mgr, NowPlayingWidget::class.java)) {
            val partial = RemoteViews(context.packageName, R.layout.now_playing_widget)
            partial.setTextViewText(R.id.widget_time_elapsed, elapsed)
            partial.setTextViewText(R.id.widget_time_remaining, remaining)
            if (refreshBar) {
                partial.setImageViewBitmap(
                    R.id.widget_progress,
                    drawProgressBar(bigBarWidthPx(minWidthDp(mgr, id), density), (12 * density).toInt(), times.fraction, true, density)
                )
            }
            mgr.partiallyUpdateAppWidget(id, partial)
        }

        for (id in ids(context, mgr, NowPlayingWidgetCompact::class.java)) {
            val partial = RemoteViews(context.packageName, R.layout.now_playing_widget_compact)
            partial.setTextViewText(R.id.widget_time_elapsed, elapsed)
            partial.setTextViewText(R.id.widget_time_remaining, remaining)
            if (refreshBar) {
                partial.setImageViewBitmap(
                    R.id.widget_progress,
                    drawProgressBar(compactBarWidthPx(minWidthDp(mgr, id), density), (8 * density).toInt(), times.fraction, true, density)
                )
            }
            mgr.partiallyUpdateAppWidget(id, partial)
        }
    }
}
