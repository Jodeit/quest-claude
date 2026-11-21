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
    companion object {
        /** Size of the detached session; the in-app mirror is laid out for this. */
        const val COLS = 110
        const val ROWS = 34
        const val NO_SESSION = "__QC_NO_SESSION__"
    }

    private val tmux = "${Termux.PREFIX}/bin/tmux"

    /**
     * Typed input, in order: "L:text" literal keys, "K:name" a tmux key name (Enter, C-c, BTab,
     * Up, ...), "P:text" a bracketed paste. Result arrives with label "input"; any tmux error
     * shows up as stdout rather than a failed command, since Termux posts a notification for
     * every failure and this runs per keystroke batch.
     */
    fun input(ops: List<String>) {
        val script = """
            t="${'$'}1"; shift
            for a; do
              case "${'$'}a" in
                L:*) $tmux send-keys -t "${'$'}t" -l -- "${'$'}{a#L:}" ;;
                K:*) $tmux send-keys -t "${'$'}t" "${'$'}{a#K:}" ;;
                P:*) $tmux set-buffer -b qc -- "${'$'}{a#P:}" && $tmux paste-buffer -p -d -b qc -t "${'$'}t" ;;
              esac
            done 2>&1
            exit 0
        """.trimIndent()
        Termux.sh(ctx, "input", script, settings.session, *ops.toTypedArray())
    }

    /** Open (or re-attach) the tmux session in a visible Termux terminal. */
    fun openSession() = open("open", settings.session, settings.launchCommand)

    /**
     * Open (or re-attach) a separate session running `claude remote-control`, so the same
     * headset session can be driven from claude.ai or the Claude app on another device.
     * Visible, because the first run prints a link and may ask for confirmation.
     */
    fun openRemote() = open("remote", Settings.REMOTE_SESSION, settings.remoteCommand)

    /**
     * Make sure tmux is installed and the Claude session is running, without opening a Termux
     * window. Installs tmux on first run (takes a minute), then starts the session detached.
     */
    fun ensureSession() {
        Termux.sh(
            ctx, "start",
            """
            command -v tmux >/dev/null 2>&1 || yes | pkg install -y tmux >/dev/null 2>&1 ||
              { echo "couldn't install tmux; run 'pkg install tmux' in Termux" >&2; exit 1; }
            # If the command exits, keep the pane open with its output and exit code, so the
            # error shows in the mirror instead of the session silently disappearing.
            $tmux has-session -t "${'$'}1" 2>/dev/null ||
              $tmux new-session -d -s "${'$'}1" -x $COLS -y $ROWS \
                "${'$'}2; ec=\${'$'}?; echo; echo \"[exited with code \${'$'}ec] press Enter to close\"; read _"
            """.trimIndent(),
            settings.session, settings.launchCommand
        )
    }

    /** Text of the Claude pane; arrives in ResultReceiver as stdout with label "mirror". */
    fun capture() {
        // Always exit 0: Termux posts a notification for every failed plugin command.
        Termux.sh(
            ctx, "mirror",
            // First line: cursor column, row and visibility; then the pane with color escapes.
            "$tmux display -p -t \"${'$'}1\" '#{cursor_x} #{cursor_y} #{cursor_flag}' 2>/dev/null &&" +
                " $tmux capture-pane -p -e -t \"${'$'}1\" 2>/dev/null || echo $NO_SESSION; exit 0",
            settings.session
        )
    }

    /** Run the reconnect command (default `quest up`) in the background; result shows in the UI. */
    fun reconnect() {
        Termux.sh(ctx, "reconnect", "exec ${Termux.PREFIX}/bin/sh -c \"\$1\"", settings.reconnectCommand)
    }

    private fun open(label: String, session: String, command: String) {
        Termux.sh(
            ctx, label,
            "exec $tmux new-session -A -s \"\$1\" \"\$2\"",
            session, command,
            background = false
        )
    }
}
