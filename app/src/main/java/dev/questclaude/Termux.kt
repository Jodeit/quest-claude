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

        /**
         * Command for a tab running Claude in ~/[project] (home when null). With [worktree],
         * Claude starts in its own git worktree and branch (`claude -w`), so tabs on the same
         * repo never edit the same files.
         */
        fun claudeIn(project: String?, worktree: String?): String {
            val dir = if (project == null) "~" else "~/" + shq(project)
            val inner = "cd $dir && claude" + (worktree?.let { " -w " + shq(it) } ?: "")
            return "proot-distro login ubuntu -- bash -lc " + shq(inner)
        }

        private fun shq(s: String) = "'" + s.replace("'", "'\\''") + "'"
    }

    private val tmux = "${Termux.PREFIX}/bin/tmux"

    /**
     * Typed input, in order: "L:text" literal keys, "K:name" a tmux key name (Enter, C-c, BTab,
     * Up, ...), "N:count:name" that key repeated, "P:text" a bracketed paste, "S:lines" scroll
     * back (positive) or forward (negative), "C:" clear Claude's prompt. Result arrives with label "input"; any tmux error
     * shows up as stdout rather than a failed command, since Termux posts a notification for
     * every failure and this runs per keystroke batch.
     */
    fun input(ops: List<String>) {
        val script = """
            t="=${'$'}1:"; shift
            for a; do
              case "${'$'}a" in
                L:*) $tmux send-keys -t "${'$'}t" -l -- "${'$'}{a#L:}" ;;
                K:*) $tmux send-keys -t "${'$'}t" "${'$'}{a#K:}" ;;
                N:*) n="${'$'}{a#N:}"; $tmux send-keys -t "${'$'}t" -N "${'$'}{n%%:*}" "${'$'}{n#*:}" ;;
                P:*) $tmux set-buffer -b qc -- "${'$'}{a#P:}" && $tmux paste-buffer -p -d -b qc -t "${'$'}t" ;;
                S:*) n="${'$'}{a#S:}"; m="${'$'}{n#-}"
                  if [ "${'$'}($tmux display -p -t "${'$'}t" '#{mouse_any_flag}')" = 1 ]; then
                    # Claude's fullscreen view keeps the transcript itself and asks for the mouse:
                    # send it SGR wheel events (64 = up, 65 = down), one per line.
                    b=64; [ "${'$'}n" = "${'$'}m" ] || b=65; w=""
                    while [ "${'$'}m" -gt 0 ]; do w="${'$'}w${'$'}(printf '\033[<%d;2;2M' ${'$'}b)"; m=${'$'}((m - 1)); done
                    $tmux send-keys -t "${'$'}t" -l -- "${'$'}w"
                  elif [ "${'$'}n" = "${'$'}m" ]; then
                    # Anything else: tmux's own scrollback, via copy mode (-e leaves it at the bottom).
                    $tmux copy-mode -e -t "${'$'}t" && $tmux send-keys -t "${'$'}t" -X -N "${'$'}m" scroll-up
                  elif [ "${'$'}($tmux display -p -t "${'$'}t" '#{pane_in_mode}')" = 1 ]; then
                    $tmux send-keys -t "${'$'}t" -X -N "${'$'}m" scroll-down
                  fi ;;
                C:) # Esc and Ctrl-C would interrupt Claude mid-turn, so delete the draft a line or
                  # two per step (Claude drops control keys sent in one big burst), checking the
                  # input box between steps. No box found (a menu, not Claude): do nothing.
                  i=0
                  while [ ${'$'}i -lt 100 ]; do
                    s=${'$'}($tmux capture-pane -p -t "${'$'}t" | ${Termux.PREFIX}/bin/awk '
                      p ~ /^─/ && /^❯/ { f = 1; l = ${'$'}0; gsub(/[ \302\240]/, "", l); getline n
                                         s = (l == "❯" && n ~ /^─/) ? "empty" : "text" }
                      { p = ${'$'}0 } END { print f ? s : "none" }')
                    [ "${'$'}s" = text ] || break
                    $tmux send-keys -t "${'$'}t" C-k C-u BSpace DC
                    sleep 0.05; i=${'$'}((i + 1))
                  done ;;
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
    fun ensureSession() = startSession(settings.session)

    /** Start [name] running the launch command, detached, unless it already exists. */
    fun startSession(name: String, command: String = settings.launchCommand) {
        Termux.sh(
            ctx, "start",
            """
            command -v tmux >/dev/null 2>&1 || yes | pkg install -y tmux >/dev/null 2>&1 ||
              { echo "couldn't install tmux; run 'pkg install tmux' in Termux" >&2; exit 1; }
            # If the command exits, keep the pane open with its output and exit code, so the
            # error shows in the mirror instead of the session silently disappearing.
            $tmux has-session -t "=${'$'}1" 2>/dev/null ||
              $tmux new-session -d -s "${'$'}1" -x $COLS -y $ROWS \
                "${'$'}2; ec=\${'$'}?; echo; echo \"[exited with code \${'$'}ec] press Enter to close\"; read _"
            """.trimIndent(),
            name, command
        )
    }

    /**
     * Git repos directly under Ubuntu's home, one name per line, as stdout with label
     * "projects". Read straight from the proot rootfs, so it doesn't need to start Ubuntu.
     * Worktrees (where .git is a file) are skipped.
     */
    fun listProjects() {
        Termux.sh(
            ctx, "projects",
            """
            b=${Termux.PREFIX}/var/lib/proot-distro
            for r in "${'$'}b"/containers/ubuntu/*/ "${'$'}b"/installed-rootfs/ubuntu/; do
              [ -f "${'$'}r/etc/os-release" ] || continue
              for d in "${'$'}r"/root/*/; do [ -d "${'$'}d.git" ] && basename "${'$'}d"; done
              exit 0
            done
            # Unknown layout: ask Ubuntu itself (slower, starts proot).
            proot-distro login ubuntu -- bash -c 'for d in ~/*/; do [ -d "${'$'}d.git" ] && basename "${'$'}d"; done' 2>/dev/null
            exit 0
            """.trimIndent()
        )
    }

    /** End a session and whatever runs in it. */
    fun killSession(name: String) {
        Termux.sh(ctx, "close", "$tmux kill-session -t \"=${'$'}1\" 2>&1; exit 0", name)
    }

    /** Session list plus the active pane; arrives in ResultReceiver as stdout with label "mirror". */
    fun capture() {
        // Always exit 0: Termux posts a notification for every failed plugin command.
        Termux.sh(
            ctx, "mirror",
            // Line 1: all session names, tab-separated (for the tab strip). Line 2: cursor column,
            // row and visibility. Then the pane with color escapes; if it's scrolled back in copy
            // mode, the lines it's showing, with no cursor.
            """
            t="=${'$'}1:"
            $tmux list-sessions -F '#{session_name}' 2>/dev/null | tr '\n' '\t'; echo
            set -- ${'$'}($tmux display -p -t "${'$'}t" '#{cursor_x} #{cursor_y} #{cursor_flag} #{pane_in_mode} #{scroll_position} #{pane_height}' 2>/dev/null)
            [ ${'$'}# -ge 3 ] || { echo $NO_SESSION; exit 0; }
            if [ "${'$'}4" = 1 ] && [ -n "${'$'}5" ]; then
              echo "${'$'}1 ${'$'}2 0"
              $tmux capture-pane -p -e -t "${'$'}t" -S "-${'$'}5" -E "${'$'}((${'$'}6 - 1 - ${'$'}5))" 2>/dev/null
            else
              echo "${'$'}1 ${'$'}2 ${'$'}3"
              $tmux capture-pane -p -e -t "${'$'}t" 2>/dev/null
            fi
            exit 0
            """.trimIndent(),
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
