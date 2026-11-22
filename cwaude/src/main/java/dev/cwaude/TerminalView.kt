package dev.cwaude

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
    /** Lines scrolled back (positive) or forward, before they're sent; for a local preview. */
    var onScroll: ((Int) -> Unit)? = null
    /** Opens a tapped link. */
    var onLink: ((String) -> Unit)? = null

    companion object {
        private const val BASE_SP = 12f
        private const val MIN_SP = 8f
        private const val MAX_SP = 20f
        /** Transcript lines per thumbstick/wheel notch. */
        private const val WHEEL_LINES = 3f
        private val URL = Regex("""https?://[^\s"'<>]+""")

        /**
         * Long-press selects text in place (Android's own handles and Copy). Copy puts the text
         * on the clipboard through [copy] with tmux's line wraps taken out, so a long link copies
         * whole; [ended] runs when the selection closes.
         */
        fun selectable(tv: android.widget.TextView, copy: (String) -> Unit, ended: () -> Unit = {}) {
            tv.setTextIsSelectable(true)
            tv.customSelectionActionModeCallback = object : android.view.ActionMode.Callback {
                override fun onCreateActionMode(m: android.view.ActionMode, menu: android.view.Menu) = true
                override fun onPrepareActionMode(m: android.view.ActionMode, menu: android.view.Menu) = false
                override fun onActionItemClicked(m: android.view.ActionMode, item: android.view.MenuItem): Boolean {
                    if (item.itemId != android.R.id.copy) return false
                    val a = minOf(tv.selectionStart, tv.selectionEnd)
                    val b = maxOf(tv.selectionStart, tv.selectionEnd)
                    if (a in 0 until b) copy(unwrap(tv.text.toString(), a, b))
                    m.finish()
                    return true
                }
                override fun onDestroyActionMode(m: android.view.ActionMode) = ended()
            }
        }

        /** [text] from [a] to [b], minus the newlines tmux added where a line filled the width. */
        fun unwrap(text: String, a: Int, b: Int): String {
            val out = StringBuilder()
            for (i in a until b) {
                val c = text[i]
                if (c == '\n' && i - (text.lastIndexOf('\n', i - 1) + 1) >= Tmux.COLS) continue
                out.append(c)
            }
            return out.toString().lines().joinToString("\n") { it.trimEnd() }
        }

        /** The link at [off], following it across wrapped lines; null if there's none there. */
        fun linkAt(text: String, off: Int): String? {
            if (off !in text.indices) return null
            var start = text.lastIndexOf('\n', off - 1) + 1
            var end = text.indexOf('\n', off).let { if (it < 0) text.length else it }
            // Grow to the whole wrapped line: earlier lines that filled the width, and later ones.
            while (start > 0) {
                val prev = text.lastIndexOf('\n', start - 2) + 1
                if (start - 1 - prev >= Tmux.COLS) start = prev else break
            }
            while (end < text.length && end - (text.lastIndexOf('\n', end - 1) + 1) >= Tmux.COLS)
                end = text.indexOf('\n', end + 1).let { if (it < 0) text.length else it }
            val joined = unwrap(text, start, end)
            val at = off - start - text.substring(start, off).count { it == '\n' }
            return URL.findAll(joined).firstOrNull { at in it.range }?.value?.trimEnd('.', ',', ')')
        }
    }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        selectable(this, { onCopy?.invoke(it) }, { onSelectionEnd?.invoke() })
        setOnClickListener {
            // A tap that only closes a selection shouldn't pop the keyboard.
            if (!selAtDown && !tapControl() && !tapLink()) showKeyboard()
        }
    }

    var onCopy: ((String) -> Unit)? = null
    /** The selection closed; the screen can update again (see MainActivity.showPane). */
    var onSelectionEnd: (() -> Unit)? = null
    private var selAtDown = false

    private fun tapLink(): Boolean {
        if (layout == null) return false
        val url = linkAt(text.toString(), getOffsetForPosition(tapX, tapY)) ?: return false
        onLink?.invoke(url)
        return true
    }

    // ---- Tapping Claude's controls (see TapTargets) -----------------------------

    private var tapX = 0f
    private var tapY = 0f

    /** Tap on a marked option or shortcut hint: send its key. False if the tap missed them all. */
    private fun tapControl(): Boolean {
        val q = input ?: return false
        if (layout == null) return false
        val off = getOffsetForPosition(tapX, tapY)
        if (off < 0) return false
        val tap = TapTargets.at(text, off) ?: return false
        Log.i("Cwaude", "tap control key=${tap.key} literal=${tap.literal}")
        tap.key?.split(' ')?.forEach(q::key)
        tap.literal?.let(q::literal)
        // A slash command: clear any draft so it runs on its own.
        tap.command?.let { q.clearPrompt(); q.literal(it); q.key("Enter") }
        return true
    }

    // ---- Scrolling: thumbstick / wheel, and pinch-drag -------------------------
    // Normally the conversation is tmux scrollback, mirrored above this view, and scrolling is
    // the ScrollView's own. When Claude runs fullscreen it keeps the transcript itself, so
    // scrolls over this view are sent to Claude (as mouse wheel events) instead.

    /** Claude asked for the mouse (fullscreen mode): scrolls here go to Claude. */
    var remoteScroll = false

    private val touchSlop = android.view.ViewConfiguration.get(ctx).scaledTouchSlop
    private var scrollAcc = 0f
    private var downY = 0f
    private var lastY = 0f
    private var dragging = false

    private fun scrollBy(lines: Float) {
        scrollAcc += lines
        val whole = scrollAcc.toInt()
        if (whole != 0) { scrollAcc -= whole; onScroll?.invoke(whole); input?.scroll(whole) }
    }

    /** Controller thumbstick (and mouse wheel): positive AXIS_VSCROLL means up, i.e. back. */
    override fun onGenericMotionEvent(event: android.view.MotionEvent): Boolean {
        if (remoteScroll && event.action == android.view.MotionEvent.ACTION_SCROLL) {
            val v = event.getAxisValue(android.view.MotionEvent.AXIS_VSCROLL)
            if (v != 0f) { scrollBy(v * WHEEL_LINES); return true }
        }
        return super.onGenericMotionEvent(event)
    }

    /** Pinch (or finger) and drag: the text follows your hand, a line per line height. Tap still types. */
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        if (event.actionMasked == android.view.MotionEvent.ACTION_DOWN) { tapX = event.x; tapY = event.y; selAtDown = hasSelection() }
        if (!remoteScroll) { dragging = false; return super.onTouchEvent(event) }
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
     * Scale the text so a full-width line (Claude's ─ rules span all [Tmux.COLS] columns)
     * fits the view exactly. ─ comes from a fallback font, so measure it rather than assume
     * the monospace advance.
     */
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val avail = w - totalPaddingLeft - totalPaddingRight
        if (avail <= 0 || w == oldw) return
        val p = android.text.TextPaint(paint)
        p.textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, BASE_SP, resources.displayMetrics)
        val cols = Tmux.COLS
        val needed = maxOf(p.measureText("─".repeat(cols)), p.measureText("M".repeat(cols)))
        val sp = (BASE_SP * avail / needed * 0.995f).coerceIn(MIN_SP, MAX_SP)
        Log.i("Cwaude", "terminal fit: ${cols} cols need ${needed / resources.displayMetrics.density}dp " +
            "at ${BASE_SP}sp (─=${p.measureText("─")}px M=${p.measureText("M")}px); " +
            "view ${avail / resources.displayMetrics.density}dp -> ${sp}sp")
        post { setTextSize(TypedValue.COMPLEX_UNIT_SP, sp) }
    }

    fun showKeyboard() {
        requestFocus()
        context.getSystemService(InputMethodManager::class.java).showSoftInput(this, 0)
    }

    /**
     * Selectable text puts the selection back at 0 on every new frame and then scrolls that
     * point into view: the screen's top line, so reading back got pulled down to it and the
     * bottom bounced. MainActivity decides scrolling; only a selection being dragged moves it.
     */
    override fun requestRectangleOnScreen(rectangle: android.graphics.Rect, immediate: Boolean) =
        hasSelection() && super.requestRectangleOnScreen(rectangle, immediate)

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
            // → accepts Claude's suggested prompt, like Tab; otherwise it moves the cursor.
            KeyEvent.KEYCODE_DPAD_RIGHT -> if (TapTargets.hasSuggestion(text)) "Tab" else "Right"
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
 * Keystrokes for tmux, sent one batch at a time. Batches with scrolls or pastes run as their own process, so
 * firing them as fast as you type could reorder letters; instead we wait for each batch's result
 * (or a timeout) and send whatever piled up meanwhile as the next batch.
 */
class InputQueue(private val send: (List<String>) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<String>()
    private var inFlight = false
    private var sentAt = 0L
    private var scrollInFlight = false
    /** A scroll is queued: captures taken before it runs would jump back. */
    val scrollQueued get() = pending.any { it.startsWith("S:") }
    /** A scroll is queued or running, so a capture taken now may be out of date. */
    val scrolling get() = scrollQueued || (inFlight && scrollInFlight)
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

    /** Call when the batch has been handed to tmux. */
    fun done() {
        if (inFlight) Log.i("Cwaude", "input round trip ${System.currentTimeMillis() - sentAt} ms")
        main.removeCallbacks(timeout)
        inFlight = false
        flush()
    }

    private fun flush() {
        if (inFlight || pending.isEmpty()) return
        val ops = pending.toList()
        pending.clear()
        inFlight = true
        sentAt = System.currentTimeMillis()
        scrollInFlight = ops.any { it.startsWith("S:") }
        main.postDelayed(timeout, 4000)
        send(ops)
    }
}
