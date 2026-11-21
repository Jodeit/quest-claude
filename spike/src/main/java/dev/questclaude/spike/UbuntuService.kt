package dev.questclaude.spike

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
import java.io.File
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Keeps Ubuntu's tmux server alive while the app is in the background: what Termux's own
 * foreground service does today. One proot runs `tmux -D` (the server, not daemonized), so
 * that process's lifetime is the server's; sessions and the control client are separate,
 * short-lived proots that reach it through its socket in the rootfs.
 */
class UbuntuService : Service() {
    companion object {
        const val SESSION = "claude"
        const val COLS = 110
        const val ROWS = 34
        private const val CHANNEL = "ubuntu"

        @Volatile var instance: UbuntuService? = null
            private set
        /** The mirror, while it's on screen. */
        @Volatile var listener: Listener? = null

        fun start(ctx: Context) {
            ctx.startForegroundService(Intent(ctx, UbuntuService::class.java))
        }
    }

    interface Listener : TmuxControl.Events {
        fun status(s: String)
    }

    private val worker = Executors.newSingleThreadExecutor()
    private var server: Process? = null
    @Volatile var control: TmuxControl? = null
        private set
    @Volatile var lastStatus = "starting"
        private set

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        SpikeLog.init(this, fresh = false)
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Ubuntu", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MirrorActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync_noanim)
            .setContentTitle("Ubuntu is running")
            .setContentText("tmux session '$SESSION'")
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(1, n)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "restart" -> worker.execute { stopServer(); ensureUp() }
            "stop" -> worker.execute { stopServer(); stopSelf() }
            else -> worker.execute { ensureUp() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        stopServer()
        instance = null
        super.onDestroy()
    }

    private fun status(s: String) {
        lastStatus = s
        SpikeLog.log("service: $s")
        listener?.status(s)
    }

    /** Server, session and control client, each started only if it isn't already running. */
    private fun ensureUp() {
        if (!Proot.unpacked(this)) { status("no rootfs yet: tap Run checks on the main screen"); return }
        if (!File(Proot.rootfs(this), "root/.local/bin/claude").exists())
            status("Claude Code isn't installed in Ubuntu yet; starting the session anyway")

        if (server?.isAlive != true) {
            // A socket left by a server that died with the app would make the next tmux client
            // start its own (short-lived) server instead of waiting for ours.
            File(Proot.rootfs(this), "tmp/tmux-0/default").delete()
            status("starting tmux server")
            val p = Proot.builder(this, "exec tmux -D", killOnExit = false).start()
            p.outputStream.close()
            server = p
            thread(name = "tmux-server", isDaemon = true) {
                p.inputStream.bufferedReader().forEachLine { SpikeLog.log("server | $it") }
                val code = p.waitFor()
                status("tmux server exited ($code)")
            }
        }

        val launch = "cd ~ && claude; ec=\$?; echo; echo \"[claude exited with code \$ec] press Enter to close\"; read _"
        val code = Proot.run(
            Proot.builder(
                this,
                """
                s=/tmp/tmux-0/default; i=0
                while [ ! -S "${'$'}s" ] && [ ${'$'}i -lt 100 ]; do sleep 0.1; i=${'$'}((i + 1)); done
                [ -S "${'$'}s" ] || { echo "the tmux server didn't come up"; exit 1; }
                tmux has-session -t "=${'$'}1" 2>/dev/null ||
                  tmux new-session -d -s "${'$'}1" -x $COLS -y $ROWS "${'$'}2"
                """.trimIndent(),
                SESSION, launch,
            )
        ) { SpikeLog.log("setup | $it") }
        if (code != 0) { status("couldn't start the session (exit $code)"); return }

        if (control?.alive != true) {
            control?.close()
            control = TmuxControl(this, SESSION, object : TmuxControl.Events {
                override fun pane(lines: List<String>, cursor: Pair<Int, Int>?, keyAt: Long, keyToOutputMs: Long) {
                    listener?.pane(lines, cursor, keyAt, keyToOutputMs)
                }
                override fun closed(why: String) {
                    status("control client closed: $why")
                    listener?.closed(why)
                }
            }).also { it.start() }
        }
        status("up: server pid-alive=${server?.isAlive}, session '$SESSION', control attached")
    }

    private fun stopServer() {
        control?.close(); control = null
        try {
            Proot.run(Proot.builder(this, "tmux kill-server 2>&1; exit 0")) { SpikeLog.log("stop | $it") }
        } catch (e: Exception) { SpikeLog.log("stop: ${e.message}") }
        server?.destroy(); server = null
    }
}
