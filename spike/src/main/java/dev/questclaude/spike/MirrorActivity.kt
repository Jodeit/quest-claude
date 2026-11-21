package dev.questclaude.spike

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.os.SystemClock
import android.text.InputType
import android.text.TextPaint
import android.util.TypedValue
import android.view.KeyEvent
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * The Claude pane, fed by [TmuxControl] through [UbuntuService] instead of polled Termux
 * commands. The status line shows key→%output (tmux saw Claude redraw) and key→screen (the
 * frame is on the panel) for the last keystroke.
 *
 * Over adb: `am start -n dev.questclaude.spike/.MirrorActivity -e text 'hi' -e key Enter`.
 */
class MirrorActivity : Activity(), UbuntuService.Listener {
    private lateinit var pane: PaneView
    private lateinit var statusView: TextView
    private val ansi = Ansi(Color.rgb(0xE6, 0xE6, 0xE6), Color.rgb(0x14, 0x14, 0x14))
    private var statusText = ""
    private var latency = ""
    private val samples = ArrayDeque<Long>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (8 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, pad)
            setBackgroundColor(Color.rgb(0x14, 0x14, 0x14))
        }
        statusView = TextView(this).apply { textSize = 13f; typeface = Typeface.MONOSPACE; setTextColor(Color.LTGRAY) }
        root.addView(statusView)
        pane = PaneView(this).apply {
            typeface = Typeface.MONOSPACE
            setTextColor(Color.rgb(0xE6, 0xE6, 0xE6))
            setBackgroundColor(Color.rgb(0x14, 0x14, 0x14))
            text = "connecting…"
        }
        root.addView(pane, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun b(label: String, onTap: () -> Unit) = bar.addView(
            Button(this).apply { text = label; isAllCaps = false; setOnClickListener { onTap() } },
            LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f),
        )
        b("Esc") { control()?.key("Escape") }
        b("^C") { control()?.key("C-c") }
        b("Tab") { control()?.key("Tab") }
        b("⇧Tab") { control()?.key("BTab") }
        b("↑") { control()?.key("Up") }
        b("↓") { control()?.key("Down") }
        b("Enter") { control()?.key("Enter") }
        b("⌨") { pane.showKeyboard() }
        b("Restart") { startService(Intent(this, UbuntuService::class.java).setAction("restart")) }
        root.addView(bar)
        setContentView(root)
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /** adb hooks for testing: -e text '…' types it, -e key Enter presses a tmux key. */
    private fun handle(i: Intent?) {
        val text = i?.getStringExtra("text")
        val key = i?.getStringExtra("key")
        if (text == null && key == null) return
        pane.postDelayed({
            text?.let { control()?.literal(it) }
            key?.let { control()?.key(it) }
        }, 300)
    }

    override fun onStart() {
        super.onStart()
        UbuntuService.listener = this
        UbuntuService.start(this)
        status(UbuntuService.instance?.lastStatus ?: "starting service")
        pane.requestFocus()
    }

    override fun onStop() {
        if (UbuntuService.listener === this) UbuntuService.listener = null
        super.onStop()
    }

    private fun control() = UbuntuService.instance?.control

    // ---- UbuntuService.Listener (any thread) ----

    override fun status(s: String) = runOnUiThread { statusText = s; showStatus() }

    override fun closed(why: String) = runOnUiThread { statusText = "disconnected: $why"; showStatus() }

    override fun pane(lines: List<String>, cursor: Pair<Int, Int>?, keyAt: Long, keyToOutputMs: Long) {
        val styled = ansi.render(lines.joinToString("\n"), cursor)
        runOnUiThread {
            pane.text = styled
            if (keyAt != 0L) {
                // Measured once the text is set; the draw itself follows on the next vsync.
                val toScreen = SystemClock.elapsedRealtime() - keyAt
                samples.addLast(toScreen); while (samples.size > 20) samples.removeFirst()
                latency = "key→output ${keyToOutputMs} ms, key→screen $toScreen ms " +
                    "(median of ${samples.size}: ${samples.sorted()[samples.size / 2]} ms)"
                SpikeLog.log("latency: $latency")
                showStatus()
            }
        }
    }

    private fun showStatus() {
        statusView.text = if (latency.isEmpty()) statusText else "$statusText\n$latency"
    }
}

/** The pane mirror; typing goes to tmux like a terminal (trimmed from the main app's TerminalView). */
class PaneView(ctx: Context) : TextView(ctx) {
    companion object { private const val BASE_SP = 12f }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setOnClickListener { showKeyboard() }
    }

    private fun control() = UbuntuService.instance?.control

    /** Scale the text so 110 columns (Claude's ─ rules span them all) fit the width exactly. */
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val avail = w - totalPaddingLeft - totalPaddingRight
        if (avail <= 0 || w == oldw) return
        val p = TextPaint(paint)
        p.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, BASE_SP, resources.displayMetrics)
        val cols = UbuntuService.COLS
        val needed = maxOf(p.measureText("─".repeat(cols)), p.measureText("M".repeat(cols)))
        val sp = (BASE_SP * avail / needed * 0.995f).coerceIn(8f, 20f)
        post { setTextSize(TypedValue.COMPLEX_UNIT_SP, sp) }
    }

    fun showKeyboard() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java).showSoftInput(this, 0)
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_ACTION_NONE
        return Connection()
    }

    /** IME edits as keystrokes; composing text is sent as it changes, as diffs. */
    private inner class Connection : BaseInputConnection(this@PaneView, false) {
        private var composing = ""

        private fun replaceComposing(text: String) {
            val common = composing.commonPrefixWith(text).length
            control()?.key("BSpace", composing.length - common)
            typeText(text.substring(common))
            composing = text
        }

        override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
            replaceComposing(text.toString()); composing = ""; return true
        }
        override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
            replaceComposing(text.toString()); return true
        }
        override fun finishComposingText(): Boolean { composing = ""; return true }
        override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
            control()?.key("BSpace", beforeLength); control()?.key("DC", afterLength); return true
        }
        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) handleKey(event)
            return true
        }
        override fun performEditorAction(actionCode: Int): Boolean { control()?.key("Enter"); return true }
    }

    private fun typeText(s: String) {
        val lines = s.split('\n')
        lines.forEachIndexed { i, line ->
            if (line.isNotEmpty()) control()?.literal(line)
            if (i < lines.size - 1) control()?.key("Enter")
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        handleKey(event) || super.onKeyDown(keyCode, event)

    private fun handleKey(ev: KeyEvent): Boolean {
        val c = control() ?: return false
        val named = when (ev.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER ->
                if (ev.isShiftPressed || ev.isAltPressed) "M-Enter" else "Enter"
            KeyEvent.KEYCODE_DEL -> "BSpace"
            KeyEvent.KEYCODE_FORWARD_DEL -> "DC"
            KeyEvent.KEYCODE_TAB -> if (ev.isShiftPressed) "BTab" else "Tab"
            KeyEvent.KEYCODE_ESCAPE -> "Escape"
            KeyEvent.KEYCODE_DPAD_UP -> "Up"
            KeyEvent.KEYCODE_DPAD_DOWN -> "Down"
            KeyEvent.KEYCODE_DPAD_LEFT -> "Left"
            KeyEvent.KEYCODE_DPAD_RIGHT -> "Right"
            KeyEvent.KEYCODE_MOVE_HOME -> "Home"
            KeyEvent.KEYCODE_MOVE_END -> "End"
            KeyEvent.KEYCODE_PAGE_UP -> "PPage"
            KeyEvent.KEYCODE_PAGE_DOWN -> "NPage"
            else -> null
        }
        if (named != null) { c.key(named); return true }
        val ch = ev.getUnicodeChar(ev.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
        if (ch == 0 || ev.isSystem) return false
        val k = ch.toChar()
        when {
            ev.isCtrlPressed -> c.key("C-${k.lowercaseChar()}")
            ev.isAltPressed -> c.key("M-$k")
            else -> c.literal(k.toString())
        }
        return true
    }
}
