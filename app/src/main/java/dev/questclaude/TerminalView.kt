package dev.questclaude

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.AttributeSet
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import androidx.appcompat.widget.AppCompatTextView

/**
 * The Claude pane mirror, which also takes typing like a terminal: hardware keys and the
 * on-screen keyboard go straight to tmux through [input].
 */
class TerminalView @JvmOverloads constructor(
    ctx: Context, attrs: AttributeSet? = null,
) : AppCompatTextView(ctx, attrs) {

    var input: InputQueue? = null

    companion object {
        private const val BASE_SP = 12f
        private const val MIN_SP = 8f
        private const val MAX_SP = 20f
        /** Transcript lines per thumbstick/wheel notch. */
        private const val WHEEL_LINES = 3f
    }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setOnClickListener { showKeyboard() }
    }

    // ---- Scrolling: thumbstick / wheel, and pinch-drag -------------------------
    // The mirror only ever shows Claude's screen, so scrolling doesn't move this view: it's
    // sent to Claude (as mouse wheel events) and the next capture shows the earlier messages.

    private val touchSlop = android.view.ViewConfiguration.get(ctx).scaledTouchSlop
    private var scrollAcc = 0f
    private var downY = 0f
    private var lastY = 0f
    private var dragging = false

    private fun scrollBy(lines: Float) {
        scrollAcc += lines
        val whole = scrollAcc.toInt()
        if (whole != 0) { scrollAcc -= whole; input?.scroll(whole) }
    }

    /** Controller thumbstick (and mouse wheel): positive AXIS_VSCROLL means up, i.e. back. */
    override fun onGenericMotionEvent(event: android.view.MotionEvent): Boolean {
        if (event.action == android.view.MotionEvent.ACTION_SCROLL) {
            val v = event.getAxisValue(android.view.MotionEvent.AXIS_VSCROLL)
            if (v != 0f) { scrollBy(v * WHEEL_LINES); return true }
        }
        return super.onGenericMotionEvent(event)
    }

    /** Pinch (or finger) and drag: the text follows your hand, a line per line height. Tap still types. */
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                downY = event.y; lastY = event.y; dragging = false; scrollAcc = 0f
                parent?.requestDisallowInterceptTouchEvent(true)
            }
            android.view.MotionEvent.ACTION_MOVE -> {
                if (!dragging && kotlin.math.abs(event.y - downY) > touchSlop) {
                    dragging = true; lastY = event.y
                    cancelLongPress()
                }
                if (dragging) {
                    scrollBy((event.y - lastY) / lineHeight.coerceAtLeast(1))
                    lastY = event.y
                    return true
                }
            }
            android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                if (dragging) { dragging = false; return true }
            }
        }
        return super.onTouchEvent(event)
    }

    /**
     * Scale the text so a full-width line (Claude's ─ rules span all [TmuxBridge.COLS] columns)
     * fits the view exactly. ─ comes from a fallback font, so measure it rather than assume
     * the monospace advance.
     */
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val avail = w - totalPaddingLeft - totalPaddingRight
        if (avail <= 0 || w == oldw) return
        val p = android.text.TextPaint(paint)
        p.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, BASE_SP, resources.displayMetrics)
        val cols = TmuxBridge.COLS
        val needed = maxOf(p.measureText("─".repeat(cols)), p.measureText("M".repeat(cols)))
        val sp = (BASE_SP * avail / needed * 0.995f).coerceIn(MIN_SP, MAX_SP)
        Log.i("QuestClaude", "terminal fit: ${cols} cols need ${needed / resources.displayMetrics.density}dp " +
            "at ${BASE_SP}sp (─=${p.measureText("─")}px M=${p.measureText("M")}px); " +
            "view ${avail / resources.displayMetrics.density}dp -> ${sp}sp")
        post { setTextSize(TypedValue.COMPLEX_UNIT_SP, sp) }
    }

    fun showKeyboard() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java).showSoftInput(this, 0)
    }

    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        // No suggestions or autocorrect: every key should reach Claude as typed.
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or
            InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN or
            EditorInfo.IME_ACTION_NONE
        return Connection()
    }

    /** Turns IME edits into keystrokes. Composing text is sent as it changes, as diffs. */
    private inner class Connection : BaseInputConnection(this@TerminalView, false) {
        private var composing = ""

        private fun replaceComposing(text: String) {
            val common = composing.commonPrefixWith(text).length
            input?.keys("BSpace", composing.length - common)
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
            input?.keys("BSpace", beforeLength)
            input?.keys("DC", afterLength)
            return true
        }

        override fun sendKeyEvent(event: KeyEvent): Boolean {
            if (event.action == KeyEvent.ACTION_DOWN) handleKey(event)
            return true
        }

        override fun performEditorAction(actionCode: Int): Boolean { input?.key("Enter"); return true }
    }

    private fun typeText(s: String) {
        if (s.isEmpty()) return
        val lines = s.split('\n')
        lines.forEachIndexed { i, line ->
            if (line.isNotEmpty()) input?.literal(line)
            if (i < lines.size - 1) input?.key("Enter")
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean =
        handleKey(event) || super.onKeyDown(keyCode, event)

    /** Maps a key to tmux; false for keys we leave to the system (Back, volume, ...). */
    private fun handleKey(ev: KeyEvent): Boolean {
        val q = input ?: return false
        val named = when (ev.keyCode) {
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER ->
                if (ev.isShiftPressed || ev.isAltPressed) "M-Enter" else "Enter" // M-Enter = newline in Claude
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
            KeyEvent.KEYCODE_INSERT -> "IC"
            in KeyEvent.KEYCODE_F1..KeyEvent.KEYCODE_F12 -> "F${ev.keyCode - KeyEvent.KEYCODE_F1 + 1}"
            else -> null
        }
        if (named != null) { q.key(named); return true }

        val ch = ev.getUnicodeChar(ev.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
        if (ch == 0 || ev.isSystem) return false
        val c = ch.toChar()
        when {
            ev.isCtrlPressed -> q.key("C-${c.lowercaseChar()}")
            ev.isAltPressed -> q.key("M-$c")
            else -> q.literal(c.toString())
        }
        return true
    }
}

/**
 * Keystrokes for tmux, sent one batch at a time. Each Termux command runs as its own process, so
 * firing them as fast as you type could reorder letters; instead we wait for each batch's result
 * (or a timeout) and send whatever piled up meanwhile as the next batch.
 */
class InputQueue(private val send: (List<String>) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<String>()
    private var inFlight = false
    private val timeout = Runnable { inFlight = false; flush() }

    /** Scroll Claude's transcript [lines] back (positive) or forward (negative). */
    fun scroll(lines: Int) {
        if (lines == 0) return
        val last = pending.lastIndex
        if (last >= 0 && pending[last].startsWith("S:")) {
            val sum = pending[last].removePrefix("S:").toInt() + lines
            if (sum == 0) pending.removeAt(last) else pending[last] = "S:$sum"
        } else pending += "S:$lines"
        flush()
    }

    fun literal(s: String) {
        val last = pending.lastIndex
        if (last >= 0 && pending[last].startsWith("L:")) pending[last] += s else pending += "L:$s"
        flush()
    }

    fun key(name: String) { pending += "K:$name"; flush() }

    /** [name] pressed [count] times, in one tmux call. */
    fun keys(name: String, count: Int) {
        if (count <= 0) return
        if (count == 1) key(name) else { pending += "N:$count:$name"; flush() }
    }

    /** Empty Claude's prompt without interrupting it (unlike Esc or Ctrl-C while it works). */
    fun clearPrompt() { pending += "C:"; flush() }

    /** Bracketed paste, so newlines don't submit. */
    fun paste(s: String) { pending += "P:$s"; flush() }

    /** Call when Termux reports the batch finished. */
    fun done() {
        main.removeCallbacks(timeout)
        inFlight = false
        flush()
    }

    private fun flush() {
        if (inFlight || pending.isEmpty()) return
        val ops = pending.toList()
        pending.clear()
        inFlight = true
        main.postDelayed(timeout, 4000)
        send(ops)
    }
}
