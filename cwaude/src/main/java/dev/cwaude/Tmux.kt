package dev.cwaude

import android.content.Context
import android.os.SystemClock
import android.util.Log
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

object Tmux {
    /** Size of every session; the mirror is laid out for it. */
    const val COLS = 110
    const val ROWS = 34
    /** Scrollback lines per history request. */
    const val HISTORY_CHUNK = 500

    /** The shell command a tab runs: [command], then keep the pane open to show how it ended. */
    fun launchScript(command: String) =
        "$command; ec=\$?; echo; echo \"[exited with code \$ec] press Enter to close\"; read _"

    /**
     * Command for a tab running Claude in ~/[project] (home when null). With [worktree], Claude
     * starts in its own git worktree and branch (`claude -w`), so tabs on the same repo never
     * edit the same files.
     */
    fun claudeIn(project: String?, worktree: String?): String {
        val dir = if (project == null) "~" else "~/" + shq(project)
        return "cd $dir && claude" + (worktree?.let { " -w " + shq(it) } ?: "")
    }

    fun shq(s: String) = "'" + s.replace("'", "'\\''") + "'"

    /** [s] as one tmux command-line argument (double quotes: escape \, " and $). */
    fun tq(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$") + "\""

    /** tmux target for a session's current pane; '=' means an exact name match. */
    fun target(session: String) = tq("=$session:")
}

/**
 * One `tmux -C` client over a pipe, the whole link between the app and tmux: keys go in as
 * commands, tmux pushes `%output` whenever the attached session's pane changes, and we answer
 * with a capture (at most every [MIN_FRAME_MS]). Each command we send gets exactly one
 * `%begin … %end` block back with flags 1 (the attach itself gets one with flags 0), in order,
 * so replies are matched to callbacks first-in, first-out.
 */
class ControlClient(private val ctx: Context, private val events: Events) {
    interface Events {
        fun frame(f: Frame)
        fun tabs(tabs: List<Tab>)
        /** tmux moved this client to [session] (a switch we asked for, or a closed tab). */
        fun sessionChanged(session: String)
        fun closed(why: String)
        /** A program copied [text] into a tmux buffer (Claude's "c to copy" runs `tmux load-buffer`). */
        fun copied(text: String)
    }

    data class Frame(
        val session: String,
        val lines: List<String>,
        /** (column, row) of a visible cursor; null when hidden (Claude draws its own). */
        val cursor: Pair<Int, Int>?,
        /** The program asked for the mouse: Claude's fullscreen mode, which keeps its own transcript. */
        val fullscreen: Boolean,
        val historySize: Int,
        /** When the key this frame answers was sent (elapsedRealtime), 0 if none. */
        val keyAt: Long,
        val keyToOutputMs: Long,
    )

    /** A session for the tab strip. [title] is the pane title Claude sets ("✳ topic" etc.). */
    data class Tab(val name: String, val title: String, val approval: Boolean)

    /** A history chunk; [lines] is empty for a reset (scrollback shrank below what we had). */
    data class History(val session: String, val size: Int, val from: Int, val lines: List<String>, val reset: Boolean)

    companion object {
        const val MIN_FRAME_MS = 16L
        private const val MARK = "CWFRAME"
        private const val TAG = "Cwaude"
    }

    private val writer = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    /** Input batches, in order; some (clear prompt) wait on replies, so not the reader thread. */
    private val ops = Executors.newSingleThreadExecutor()
    private var proc: Process? = null
    private var out: OutputStream? = null

    private val lock = Any()
    private val pending = ArrayDeque<((Boolean, List<String>) -> Unit)?>()

    /** Session this client is attached to, as tmux last reported it. */
    @Volatile var session = ""
        private set
    /** While false (no UI), %output doesn't trigger captures; [resume] catches up. */
    @Volatile var active = true

    // Last frame's pane state, for scrolling.
    @Volatile private var mouse = false
    @Volatile private var inMode = false

    private var captureInFlight = false
    private var captureDirty = false
    @Volatile private var lastFrameAt = 0L
    @Volatile private var tabsInFlight = false

    // Latency of the oldest key not yet answered by a frame.
    @Volatile private var keyAt = 0L
    @Volatile private var keyOutputAt = 0L

    val alive get() = proc?.isAlive == true

    /** Attach to [session], creating it with [launch] (a shell command) if it doesn't exist. */
    fun start(session: String, launch: String) {
        this.session = session
        val p = Ubuntu.builder(
            ctx,
            "exec tmux -C new-session -A -s \"\$1\" -x ${Tmux.COLS} -y ${Tmux.ROWS} bash -lc \"\$2\"",
            session, Tmux.launchScript(launch),
        ).start()
        proc = p
        out = p.outputStream
        // A control client has no size of its own; give it the mirror's so the window keeps it.
        command("refresh-client -C ${Tmux.COLS}x${Tmux.ROWS}")
        // Closing the attached tab moves us to another one instead of ending this client.
        command("set -g detach-on-destroy off")
        thread(name = "tmux-control", isDaemon = true) { readLoop(p) }
        requestCapture()
        requestTabs()
    }

    fun close() {
        proc?.destroy()
        writer.shutdown(); timer.shutdown(); ops.shutdown()
    }

    /** UI is back: redraw now (output that came while paused didn't). */
    fun resume() {
        active = true
        requestCapture()
        requestTabs()
    }

    // ---- Commands ----

    /** Sends one tmux command; [cb] gets its reply (on the reader thread). */
    fun command(cmd: String, cb: ((ok: Boolean, lines: List<String>) -> Unit)? = null) {
        synchronized(lock) {
            // Queue the callback and the write together so their orders always match.
            pending.addLast(cb)
            writer.execute {
                try {
                    out?.apply { write((cmd + "\n").toByteArray()); flush() }
                } catch (e: Exception) {
                    Log.w(TAG, "control write failed: ${e.message}")
                }
            }
        }
    }

    /** [command], waiting for the reply. Never call it from the reader thread. */
    private fun commandSync(cmd: String, timeoutMs: Long = 3000): List<String>? {
        val done = CountDownLatch(1)
        var result: List<String>? = null
        command(cmd) { ok, lines -> if (ok) result = lines; done.countDown() }
        return if (done.await(timeoutMs, TimeUnit.MILLISECONDS)) result else null
    }

    fun switchTo(name: String) = command("switch-client -t ${Tmux.tq("=$name")}")

    fun newSession(name: String, launch: String) {
        command("new-session -d -s ${Tmux.tq(name)} -x ${Tmux.COLS} -y ${Tmux.ROWS} bash -lc ${Tmux.tq(Tmux.launchScript(launch))}")
        requestTabs()
    }

    fun killSession(name: String) {
        command("kill-session -t ${Tmux.tq("=$name")}")
        requestTabs()
    }

    // ---- Input ----

    /**
     * An [InputQueue] batch, in order: "L:text" literal, "K:name" a tmux key, "N:count:name"
     * that key repeated, "P:text" a bracketed paste, "S:lines" scroll back (+) or forward (-),
     * "C:" clear Claude's prompt. [done] runs once the batch is handed to tmux.
     */
    fun input(batch: List<String>, done: () -> Unit) = ops.execute {
        try {
            for (a in batch) when {
                a.startsWith("L:") -> literal(a.substring(2))
                a.startsWith("K:") -> key(a.substring(2))
                a.startsWith("N:") -> a.substring(2).split(':', limit = 2).let { (n, k) -> key(k, n.toIntOrNull() ?: 1) }
                a.startsWith("P:") -> bytes("\u001b[200~".toByteArray() + a.substring(2).toByteArray() + "\u001b[201~".toByteArray())
                a.startsWith("S:") -> scroll(a.substring(2).toIntOrNull() ?: 0)
                a == "C:" -> clearPrompt()
            }
        } catch (e: Exception) {
            Log.w(TAG, "input failed", e)
        }
        done()
    }

    /** Text as typed. Sent as hex bytes, so nothing in it is ever parsed by tmux or a shell. */
    private fun literal(s: String) = bytes(s.toByteArray())

    private fun bytes(b: ByteArray) {
        if (b.isEmpty()) return
        markKey()
        for (start in b.indices step 512) {
            val chunk = b.copyOfRange(start, minOf(b.size, start + 512))
            command("send-keys -H " + chunk.joinToString(" ") { "%02x".format(it) })
        }
    }

    /** A tmux key name (Enter, C-c, BTab, Up, ...), [count] times. */
    private fun key(name: String, count: Int = 1) {
        if (count <= 0) return
        markKey()
        command(if (count == 1) "send-keys $name" else "send-keys -N $count $name")
    }

    private fun markKey() {
        if (keyAt == 0L) { keyAt = SystemClock.elapsedRealtime(); keyOutputAt = 0L }
    }

    private fun scroll(n: Int) {
        val m = Math.abs(n)
        if (m == 0) return
        when {
            // Claude's fullscreen view keeps the transcript itself and asks for the mouse:
            // send it SGR wheel events (64 = up, 65 = down), one per line.
            mouse -> bytes(("\u001b[<${if (n > 0) 64 else 65};2;2M").repeat(m).toByteArray())
            // Anything else: tmux's own scrollback, via copy mode (-e leaves it at the bottom).
            n > 0 -> { command("copy-mode -e"); command("send-keys -X -N $m scroll-up") }
            inMode -> command("send-keys -X -N $m scroll-down")
        }
    }

    /**
     * Empty Claude's prompt without interrupting it: Esc and Ctrl-C would, mid-turn. Deletes a
     * line or two per step (Claude drops control keys sent in one big burst), checking the
     * input box between steps. No input box on screen (a menu, not Claude): does nothing.
     */
    private fun clearPrompt() {
        repeat(100) {
            val pane = commandSync("capture-pane -p") ?: return
            if (promptState(pane) != "text") return
            command("send-keys C-k C-u BSpace DC")
            Thread.sleep(50)
        }
    }

    /** "empty", "text" or "none": Claude's input box is a ❯ line right under a ─ rule. */
    private fun promptState(pane: List<String>): String {
        var state = "none"
        for (i in 1 until pane.size) {
            if (!pane[i - 1].startsWith("─") || !pane[i].startsWith("❯")) continue
            val l = pane[i].replace(" ", "").replace(" ", "")
            val next = pane.getOrNull(i + 1).orEmpty()
            state = if (l == "❯" && next.startsWith("─")) "empty" else "text"
        }
        return state
    }

    // ---- Frames ----

    fun requestCapture() {
        synchronized(lock) {
            if (captureInFlight) { captureDirty = true; return }
            captureInFlight = true
        }
        // No -t: the client's current pane, so a frame always matches the session it names.
        command("display -p '$MARK #{cursor_x} #{cursor_y} #{cursor_flag} #{mouse_any_flag} " +
            "#{history_size} #{pane_in_mode} #{pane_height} #{session_name} #{scroll_position}'") { ok, lines ->
            val h = lines.firstOrNull()?.takeIf { ok && it.startsWith("$MARK ") }?.split(' ')
            if (h == null || h.size < 9) { frameDone(); return@command }
            val x = h[1].toIntOrNull() ?: 0
            val y = h[2].toIntOrNull() ?: 0
            mouse = h[4] == "1"
            inMode = h[6] == "1"
            val height = h[7].toIntOrNull() ?: Tmux.ROWS
            val sess = h[8]
            val pos = h.getOrNull(9)?.toIntOrNull()
            val history = h[5].toIntOrNull() ?: 0
            // Scrolled back in copy mode: capture the lines it shows, with no cursor.
            val range = if (inMode && pos != null) " -S -$pos -E ${height - 1 - pos}" else ""
            val cursor = if (range.isEmpty() && h[3] == "1") x to y else null
            command("capture-pane -p -e -t ${Tmux.target(sess)}$range") { ok2, pane ->
                if (ok2) deliver(sess, pane, cursor, history)
                frameDone()
            }
        }
    }

    private fun frameDone() {
        val again = synchronized(lock) {
            captureInFlight = false
            captureDirty.also { captureDirty = false }
        }
        if (!again) return
        val wait = MIN_FRAME_MS - (SystemClock.elapsedRealtime() - lastFrameAt)
        if (wait > 0) timer.schedule({ requestCapture() }, wait, TimeUnit.MILLISECONDS) else requestCapture()
    }

    private fun deliver(sess: String, lines: List<String>, cursor: Pair<Int, Int>?, history: Int) {
        lastFrameAt = SystemClock.elapsedRealtime()
        val k = keyAt
        val answered = k != 0L && keyOutputAt != 0L
        if (answered) keyAt = 0L // only a frame taken after the key's own %output answers it
        events.frame(Frame(sess, lines, cursor, mouse, history,
            if (answered) k else 0L, if (answered) keyOutputAt - k else -1))
    }

    private fun onOutput() {
        if (keyAt != 0L && keyOutputAt == 0L) keyOutputAt = SystemClock.elapsedRealtime()
        if (active) requestCapture()
    }

    // ---- Tabs ----

    /** Every session, oldest first, with its pane title and whether it's asking for approval. */
    fun requestTabs() {
        if (tabsInFlight) return
        tabsInFlight = true
        command("list-sessions -F '#{session_created}|#{session_name}|#{pane_title}'") { ok, lines ->
            val entries = if (!ok) emptyList() else lines.mapNotNull {
                val f = it.split('|', limit = 3)
                if (f.size == 3) Triple(f[0].toLongOrNull() ?: 0L, f[1], f[2]) else null
            }.sortedBy { it.first }
            if (entries.isEmpty()) { tabsInFlight = false; events.tabs(emptyList()); return@command }
            val tabs = arrayOfNulls<Tab>(entries.size)
            var left = entries.size
            entries.forEachIndexed { i, (_, name, title) ->
                command("capture-pane -p -t ${Tmux.target(name)}") { _, pane ->
                    // A permission prompt: "Do you want to …" with "1. Yes" at or below it.
                    val tail = pane.takeLast(30)
                    val q = tail.indexOfFirst { "Do you want to" in it }
                    tabs[i] = Tab(name, title, q >= 0 && tail.drop(q).any { "1. Yes" in it })
                    if (--left == 0) { tabsInFlight = false; events.tabs(tabs.filterNotNull()) }
                }
            }
        }
    }

    /** [session]'s screen and recent scrollback as plain text, wrapped lines joined (-J). */
    fun screenText(session: String, cb: (String) -> Unit) =
        command("capture-pane -p -J -S -300 -t ${Tmux.target(session)}") { ok, lines ->
            cb(if (ok) lines.joinToString("\n") { it.trimEnd() }.trim('\n') else "")
        }

    // ---- Clipboard ----

    /**
     * Paste buffer [name] -> [Events.copied]. show-buffer turns newlines into '_' for control
     * clients, so tmux saves it to a file in Ubuntu's /tmp and we read that. The tmux -C client
     * writes the file, maybe just after the reply, so allow it a moment.
     */
    private fun readBuffer(name: String) {
        val file = java.io.File(Ubuntu.rootfs(ctx), "tmp/qlaude-clip")
        file.delete()
        command("save-buffer -b ${Tmux.tq(name)} /tmp/qlaude-clip") { ok, _ ->
            if (!ok) return@command
            fun attempt(n: Int) {
                if (file.exists() && (file.length() > 0 || n > 3)) {
                    val text = runCatching { file.readText() }.getOrNull()
                    file.delete()
                    if (!text.isNullOrEmpty()) events.copied(text)
                } else if (n < 20) runCatching { timer.schedule({ attempt(n + 1) }, 25, TimeUnit.MILLISECONDS) }
            }
            runCatching { timer.execute { attempt(0) } }
        }
    }

    // ---- History ----

    /**
     * Up to [Tmux.HISTORY_CHUNK] scrollback lines of [session], starting [from] lines after the
     * oldest; [cb] runs on the reader thread.
     */
    fun history(session: String, from: Int, cb: (History) -> Unit) {
        val t = Tmux.target(session)
        command("display -p -t $t '#{history_size}'") { ok, l ->
            val size = l.firstOrNull()?.trim()?.toIntOrNull()
            if (!ok || size == null || size < from) { cb(History(session, size ?: 0, from, emptyList(), true)); return@command }
            val n = minOf(size - from, Tmux.HISTORY_CHUNK)
            if (n <= 0) { cb(History(session, size, from, emptyList(), false)); return@command }
            command("capture-pane -p -e -t $t -S -${size - from} -E -${size - from - n + 1}") { ok2, lines ->
                if (ok2) cb(History(session, size, from, lines.take(n), false))
                else cb(History(session, size, from, emptyList(), true))
            }
        }
    }

    // ---- Reader ----

    private fun readLoop(p: Process) {
        var block: MutableList<String>? = null
        var ours = false
        var why = "tmux control client exited"
        try {
            p.inputStream.bufferedReader().forEachLine { line ->
                val b = block
                if (b != null) {
                    val end = line.startsWith("%end ")
                    if (end || line.startsWith("%error ")) {
                        block = null
                        if (ours) {
                            val cb = synchronized(lock) { pending.removeFirstOrNull() }
                            try { cb?.invoke(end, b) } catch (e: Exception) { Log.w(TAG, "reply handler failed", e) }
                        }
                        if (!end) Log.w(TAG, "tmux error: ${b.joinToString(" / ")}")
                    } else b += line
                    return@forEachLine
                }
                when {
                    line.startsWith("%begin ") -> { block = mutableListOf(); ours = line.trimEnd().endsWith(" 1") }
                    line.startsWith("%output ") || line.startsWith("%extended-output ") -> onOutput()
                    line.startsWith("%session-changed ") -> {
                        session = line.split(' ', limit = 3).getOrElse(2) { "" }
                        events.sessionChanged(session)
                        requestCapture()
                    }
                    // Claude's copy (and tmux copy mode) fill a paste buffer; hand it to Android.
                    line.startsWith("%paste-buffer-changed ") -> readBuffer(line.substringAfter(' ').trim())
                    line.startsWith("%sessions-changed") || line.startsWith("%session-renamed") -> requestTabs()
                    line.startsWith("%exit") -> why = "tmux: $line"
                    line.startsWith("%") -> {}
                    else -> Log.i(TAG, "control: $line") // proot warnings and the like
                }
            }
        } catch (e: Exception) {
            why = "control read failed: ${e.message}"
        }
        Log.i(TAG, "control client closed: $why")
        events.closed(why)
    }
}
