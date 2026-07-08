package com.barnabas.absorb

import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import es.antonborri.home_widget.HomeWidgetPlugin

// An app update kills the process mid-playback, but the now-playing widgets
// redraw from the stashed state, which still says playing - so they sit on a
// live squiggle with a pause button that goes nowhere. Correct the stash and
// re-render as soon as the new build is installed.
class PackageReplacedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            HomeWidgetPlugin.getData(context).edit()
                .putBoolean("widget_is_playing", false)
                .apply()
            val mgr = AppWidgetManager.getInstance(context)
            for (id in mgr.getAppWidgetIds(ComponentName(context, NowPlayingWidget::class.java))) {
                try { NowPlayingWidget.updateWidget(context, mgr, id) } catch (_: Exception) {}
            }
            for (id in mgr.getAppWidgetIds(ComponentName(context, NowPlayingWidgetCompact::class.java))) {
                try { NowPlayingWidgetCompact.updateWidget(context, mgr, id) } catch (_: Exception) {}
            }
            for (id in mgr.getAppWidgetIds(ComponentName(context, NowPlayingWidgetTiny::class.java))) {
                try { NowPlayingWidgetTiny.updateWidget(context, mgr, id) } catch (_: Exception) {}
            }
            WidgetClock.syncTicker(context)
        } catch (e: Exception) {
            android.util.Log.e("PackageReplaced", "widget reset failed", e)
        }
    }
}
