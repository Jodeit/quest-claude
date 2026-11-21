package dev.questclaude.spike

import android.content.Context
import android.os.SystemClock
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * One `tmux -C attach` client over a pipe: the replacement for a RUN_COMMAND intent per action.
 * Keys are written as tmux commands; tmux pushes `%output` whenever the pane changes, and we
 * answer with a capture (at most every [MIN_FRAME_MS]) that goes to [Events.pane].
 */
class TmuxControl(private val ctx: Context, private val session: String, private val events: Events) {
    interface Events {
        /** [lines] from `capture-pane -e`; [keyAt] is when the key this frame answers was sent (0 if none). */
        fun pane(lines: List<String>, cursor: Pair<Int, Int>?, keyAt: Long, keyToOutputMs: Long)
        fun closed(why: String)
    }

    companion object {
        const val MIN_FRAME_MS = 16L
        private const val MARK = "QCCAP"
    }

    private val writer = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private var proc: Process? = null
    private var out: OutputStream? = null

    private val lock = Any()
    private var captureInFlight = false
    private var dirty = false
    private var lastFrameAt = 0L
    /** Capture split across two response blocks: the marker came, the pane is next. */
    private var expectPane: Pair<Int, Int>? = null
    private var expectingPane = false

    // Latency of the oldest key not yet answered by a frame.
    @Volatile private var keyAt = 0L
    @Volatile private var keyOutputAt = 0L

    val alive get() = proc?.isAlive == true

    fun start() {
        val p = Proot.builder(ctx, "exec tmux -C attach -t \"=${'$'}1\"", session).start()
        proc = p
        out = p.outputStream
        // A control client has no size of its own; give it the mirror's so it never shrinks the window.
        send("refresh-client -C ${UbuntuService.COLS}x${UbuntuService.ROWS}")
        requestCapture()
        thread(name = "tmux-control", isDaemon = true) { readLoop(p) }
    }

    fun close() {
        proc?.destroy()
        writer.shutdown(); timer.shutdown()
    }

    // ---- keys ----

    /** Text typed as is: sent as hex bytes, so nothing in it is ever parsed by tmux. */
    fun literal(s: String) {
        if (s.isEmpty()) return
        sendKeys("-H " + s.toByteArray().joinToString(" ") { "%02x".format(it) })
    }

    /** A tmux key name (Enter, C-c, BTab, Up, ...), optionally repeated. */
    fun key(name: String, count: Int = 1) {
        if (count <= 0) return
        sendKeys(if (count == 1) name else "-N $count $name")
    }

    private fun sendKeys(args: String) {
        if (keyAt == 0L) { keyAt = SystemClock.elapsedRealtime(); keyOutputAt = 0L }
        send("send-keys -t =$session: $args")
    }

    private fun send(line: String) = writer.execute {
        try {
            out?.apply { write((line + "\n").toByteArray()); flush() }
        } catch (e: Exception) {
            SpikeLog.log("control: write failed: ${e.message}")
        }
    }

    // ---- frames ----

    private fun requestCapture() {
        synchronized(lock) {
            if (captureInFlight) { dirty = true; return }
            captureInFlight = true
        }
        val t = "=$session:"
        send("display -p -t $t '$MARK #{cursor_x} #{cursor_y} #{cursor_flag}' ; capture-pane -p -e -t $t")
    }

    private fun frameDone() {
        val again = synchronized(lock) {
            captureInFlight = false
            dirty.also { dirty = false }
        }
        if (!again) return
        val wait = MIN_FRAME_MS - (SystemClock.elapsedRealtime() - lastFrameAt)
        if (wait > 0) timer.schedule({ requestCapture() }, wait, TimeUnit.MILLISECONDS) else requestCapture()
    }

    private fun onOutput() {
        if (keyAt != 0L && keyOutputAt == 0L) keyOutputAt = SystemClock.elapsedRealtime()
        requestCapture()
    }

    private fun deliver(lines: List<String>, cursor: Pair<Int, Int>?) {
        lastFrameAt = SystemClock.elapsedRealtime()
        val k = keyAt
        val toOutput = if (k != 0L && keyOutputAt != 0L) keyOutputAt - k else -1
        // Only a frame taken after the key's own %output counts as answering it.
        if (k != 0L && keyOutputAt != 0L) keyAt = 0L
        events.pane(lines, cursor, if (toOutput >= 0) k else 0L, toOutput)
        frameDone()
    }

    /** One `%begin`…`%end` response. Ours start with the marker line (see [requestCapture]). */
    private fun onBlock(lines: List<String>, error: Boolean) {
        if (error) {
            SpikeLog.log("control: tmux error: ${lines.joinToString(" / ")}")
            synchronized(lock) { captureInFlight = false }
            expectingPane = false
            return
        }
        val first = lines.firstOrNull()
        if (first != null && first.startsWith("$MARK ")) {
            val f = first.split(' ')
            val cursor = if (f.getOrNull(3) == "1") (f[1].toIntOrNull() ?: 0) to (f[2].toIntOrNull() ?: 0) else null
            val rest = lines.drop(1)
            if (rest.isEmpty()) { expectPane = cursor; expectingPane = true } else deliver(rest, cursor)
        } else if (expectingPane) {
            expectingPane = false
            deliver(lines, expectPane)
        }
        // Anything else answers send-keys or refresh-client: empty, nothing to do.
    }

    private fun readLoop(p: Process) {
        var block: MutableList<String>? = null
        var why = "tmux control client exited"
        try {
            p.inputStream.bufferedReader().forEachLine { line ->
                val b = block
                if (b != null) {
                    when {
                        line.startsWith("%end ") -> { block = null; onBlock(b, false) }
                        line.startsWith("%error ") -> { block = null; onBlock(b, true) }
                        else -> b += line
                    }
                    return@forEachLine
                }
                when {
                    line.startsWith("%begin ") -> block = mutableListOf()
                    line.startsWith("%output ") || line.startsWith("%extended-output ") -> onOutput()
                    line.startsWith("%exit") -> why = "tmux: $line"
                    line.startsWith("%") -> {} // window/session notifications: not needed here
                    else -> SpikeLog.log("control: $line")
                }
            }
        } catch (e: Exception) {
            why = "control read failed: ${e.message}"
        }
        SpikeLog.log("control: closed ($why, exit ${runCatching { p.waitFor() }.getOrNull()})")
        events.closed(why)
    }
}
