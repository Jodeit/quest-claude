package dev.cwaude

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * Keeps Ubuntu's tmux server (and every Claude in it) alive while Cwaude is in the background,
 * as Termux's foreground service did for Quest Claude. One proot runs `tmux -D`, the server
 * in the foreground, so that process lives exactly as long as the server; the app reaches it
 * through one [ControlClient] in a second proot.
 */
class CwaudeService : Service() {
    companion object {
        private const val CHANNEL = "ubuntu"
        private const val TAG = "Cwaude"
        /** How often the tab strip's status (working / your turn / approve) is refreshed. */
        private const val TABS_MS = 1500L

        @Volatile var instance: CwaudeService? = null
            private set
        /** The main screen, while it's visible. */
        @Volatile var listener: Listener? = null
            set(v) { field = v; instance?.control?.let { c -> if (v != null) c.resume() else c.active = false } }

        fun start(ctx: Context) = ctx.startForegroundService(Intent(ctx, CwaudeService::class.java))
    }

    interface Listener : ControlClient.Events {
        fun status(s: String)
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val ticker = Executors.newSingleThreadScheduledExecutor()
    private var server: Process? = null
    @Volatile var control: ControlClient? = null
        private set
    @Volatile var lastStatus = "starting"
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Ubuntu", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Qlaude is running")
            .setContentText("Your Claude sessions keep going in the background.")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(1, n)
        ticker.scheduleWithFixedDelay({
            if (listener != null) control?.takeIf { it.alive }?.requestTabs()
        }, TABS_MS, TABS_MS, TimeUnit.MILLISECONDS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "stop" -> worker.execute { stopServer(); stopSelf() }
            else -> ensureUp()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        ticker.shutdown()
        stopServer()
        instance = null
        super.onDestroy()
    }

    private fun status(s: String) {
        lastStatus = s
        Log.i(TAG, "service: $s")
        listener?.status(s)
    }

    /** Server and control client, each started only if it isn't running. Cheap to call often. */
    fun ensureUp() = worker.execute {
        if (!Ubuntu.ready(this)) { status("Ubuntu isn't set up yet"); return@execute }
        try {
            if (server?.isAlive != true) startServer()
            if (control?.alive != true) startControl()
            status("up")
        } catch (e: Exception) {
            Log.w(TAG, "couldn't start", e)
            status("couldn't start Ubuntu: ${e.message}")
        }
    }

    private fun startServer() {
        // A socket left by a server that died with the app would make the next tmux client
        // start its own short-lived server instead of waiting for ours.
        val sock = Ubuntu.tmuxSocket(this)
        sock.delete()
        status("starting tmux")
        val p = Ubuntu.builder(this, "exec tmux -D", killOnExit = false).start()
        p.outputStream.close()
        server = p
        thread(name = "tmux-server", isDaemon = true) {
            p.inputStream.bufferedReader().forEachLine { Log.i(TAG, "server: $it") }
            val code = p.waitFor()
            status("tmux server exited ($code)")
        }
        val t0 = System.currentTimeMillis()
        while (!sock.exists() && System.currentTimeMillis() - t0 < 10_000) Thread.sleep(50)
        if (!sock.exists()) error("the tmux server didn't come up")
    }

    private fun startControl() {
        control?.close()
        val settings = Settings(this)
        val c = ControlClient(this, object : ControlClient.Events {
            override fun frame(f: ControlClient.Frame) { listener?.frame(f) }
            override fun tabs(tabs: List<ControlClient.Tab>) { listener?.tabs(tabs) }
            override fun sessionChanged(session: String) { listener?.sessionChanged(session) }
            // Android only lets the focused app set the clipboard, so the screen does it.
            override fun copied(text: String) { listener?.copied(text) }
            override fun closed(why: String) {
                status("disconnected: $why")
                listener?.closed(why)
            }
        })
        c.active = listener != null
        // The last tab closed leaves the client with nothing to attach to; a fresh home tab
        // comes back the same way it did at first start.
        c.start(settings.session, settings.launchCommand)
        control = c
    }

    private fun stopServer() {
        // End tmux (and every Claude) itself rather than relying on proot passing SIGTERM on.
        control?.takeIf { it.alive }?.let { it.command("kill-server"); Thread.sleep(300) }
        control?.close(); control = null
        server?.destroy(); server = null
    }
}
