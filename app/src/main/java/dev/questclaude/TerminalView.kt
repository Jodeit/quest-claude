package dev.questclaude

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.AttributeSet
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

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        setOnClickListener { showKeyboard() }
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
            repeat(composing.length - common) { input?.key("BSpace") }
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
            repeat(beforeLength) { input?.key("BSpace") }
            repeat(afterLength) { input?.key("DC") }
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

    fun literal(s: String) {
        val last = pending.lastIndex
        if (last >= 0 && pending[last].startsWith("L:")) pending[last] += s else pending += "L:$s"
        flush()
    }

    fun key(name: String) { pending += "K:$name"; flush() }

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
