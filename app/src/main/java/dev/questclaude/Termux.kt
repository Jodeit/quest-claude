package dev.questclaude

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

/** Thin wrapper around Termux's RUN_COMMAND intent. */
object Termux {
    const val PKG = "com.termux"
    const val PERMISSION = "com.termux.permission.RUN_COMMAND"
    const val PREFIX = "/data/data/com.termux/files/usr"
    const val HOME = "/data/data/com.termux/files/home"
    private const val SH = "$PREFIX/bin/sh"

    fun isInstalled(ctx: Context): Boolean = try {
        ctx.packageManager.getPackageInfo(PKG, 0); true
    } catch (e: PackageManager.NameNotFoundException) { false }

    fun hasPermission(ctx: Context): Boolean =
        ContextCompat.checkSelfPermission(ctx, PERMISSION) == PackageManager.PERMISSION_GRANTED

    /**
     * Runs `sh -c script` in Termux. Extra [args] become $1, $2, ... so user text is
     * never interpolated into shell source.
     */
    fun sh(ctx: Context, label: String, script: String, vararg args: String, background: Boolean = true) {
        val intent = Intent("com.termux.RUN_COMMAND")
            .setClassName(PKG, "com.termux.app.RunCommandService")
            .putExtra("com.termux.RUN_COMMAND_PATH", SH)
            .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arrayOf("-c", script, "qc") + args)
            .putExtra("com.termux.RUN_COMMAND_WORKDIR", HOME)
            .putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
            .putExtra("com.termux.RUN_COMMAND_COMMAND_LABEL", "Quest Claude: $label")
        if (background) {
            val result = Intent(ctx, ResultReceiver::class.java).putExtra(ResultReceiver.EXTRA_LABEL, label)
            val pi = PendingIntent.getBroadcast(
                ctx, label.hashCode(), result,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
            intent.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", pi)
        }
        ctx.startService(intent)
    }
}

/** tmux operations against the session that runs Claude Code. */
class TmuxBridge(private val ctx: Context, private val settings: Settings) {
    private val tmux = "${Termux.PREFIX}/bin/tmux"

    /** Bracketed-paste the text (so newlines don't submit early), optionally press Enter. */
    fun sendText(text: String, submit: Boolean) {
        val script = buildString {
            append("$tmux set-buffer -b qc -- \"\$1\" && ")
            append("$tmux paste-buffer -p -d -b qc -t \"\$2\"")
            if (submit) append(" && sleep 0.1 && $tmux send-keys -t \"\$2\" Enter")
        }
        Termux.sh(ctx, "send", script, text, settings.session)
    }

    /** Send tmux key names, e.g. "Escape", "C-c", "BTab", "Up". */
    fun sendKeys(vararg keys: String) {
        Termux.sh(ctx, "key", "t=\"\$1\"; shift; $tmux send-keys -t \"\$t\" \"\$@\"", settings.session, *keys)
    }

    /** Open (or re-attach) the tmux session in a visible Termux terminal. */
    fun openSession() {
        Termux.sh(
            ctx, "open",
            "exec $tmux new-session -A -s \"\$1\" \"\$2\"",
            settings.session, settings.launchCommand,
            background = false
        )
    }
}
