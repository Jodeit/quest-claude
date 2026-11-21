package dev.questclaude

import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.UnderlineSpan

/** A tappable bit of Claude's UI: tapping it sends [key] (a tmux key name) or types [literal]. */
class TapSpan(val key: String? = null, val literal: String? = null)

/**
 * Finds Claude's live controls in the pane and marks them tappable: numbered options in a
 * prompt ("❯ 1. Yes", "  2. No") and shortcut hints ("esc to interrupt", "Tab to amend",
 * "(shift+tab to cycle)"). Only text below the last full-width ─ rule counts: that's the top of
 * a dialog, or the bottom of the input box, so the transcript (which can mention "esc to
 * interrupt" or "1. Yes" too) and the prompt you're typing are never tappable.
 */
object TapTargets {
    private val RULE = Regex("^\\s*─{20,}\\s*$")
    private val OPTION = Regex("^\\s*(?:❯\\s*)?(\\d)\\.\\s+\\S")
    // "esc to interrupt", "Tab to amend", "? for shortcuts", "↓ to manage", or a bare "(esc)".
    private val HINT = Regex(
        "(?i)(?<![\\w+])(esc|shift\\+tab|ctrl\\+[a-z]|tab|enter|space|[↑↓]|\\?)" +
            "(?:( (?:to|for) [^·()\\n]*[^·()\\s])|(?=\\)))")

    private fun keyFor(word: String): TapSpan? {
        val w = word.lowercase()
        return when {
            w == "esc" -> TapSpan(key = "Escape")
            w == "shift+tab" -> TapSpan(key = "BTab")
            w.startsWith("ctrl+") -> TapSpan(key = "C-${w.last()}")
            w == "tab" -> TapSpan(key = "Tab")
            w == "enter" -> TapSpan(key = "Enter")
            w == "space" -> TapSpan(key = "Space")
            w == "↑" -> TapSpan(key = "Up")
            w == "↓" -> TapSpan(key = "Down")
            w == "?" -> TapSpan(literal = "?")
            else -> null
        }
    }

    fun mark(text: CharSequence): CharSequence {
        val s = text.toString()
        // Line start offsets.
        val starts = mutableListOf(0)
        s.forEachIndexed { i, c -> if (c == '\n') starts += i + 1 }
        fun line(n: Int) = s.substring(starts[n], if (n + 1 < starts.size) starts[n + 1] - 1 else s.length)
        val lastRule = (starts.indices).lastOrNull { RULE.matches(line(it)) } ?: return text
        if (lastRule == starts.lastIndex) return text

        val out = SpannableStringBuilder(text)
        fun span(start: Int, end: Int, tap: TapSpan) {
            if (end <= start) return
            out.setSpan(tap, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            out.setSpan(UnderlineSpan(), start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }

        for (n in lastRule + 1 until starts.size) {
            val l = line(n)
            for (m in HINT.findAll(l)) {
                val tap = keyFor(m.groupValues[1]) ?: continue
                span(starts[n] + m.range.first, starts[n] + m.range.last + 1, tap)
            }
        }
        var n = lastRule + 1
        while (n < starts.size) {
            val l = line(n)
            val opt = OPTION.find(l)
            if (opt != null) {
                // The option, plus its wrapped continuation lines (indented deeper, not options).
                val tap = TapSpan(literal = opt.groupValues[1])
                val indent = l.indexOfFirst { !it.isWhitespace() && it != '❯' }
                span(starts[n] + opt.groups[1]!!.range.first, starts[n] + l.trimEnd().length, tap)
                while (n + 1 < starts.size) {
                    val next = line(n + 1)
                    val nextIndent = next.indexOfFirst { !it.isWhitespace() }
                    if (next.isBlank() || OPTION.containsMatchIn(next) || nextIndent <= indent) break
                    n++
                    span(starts[n] + nextIndent, starts[n] + next.trimEnd().length, tap)
                }
            }
            n++
        }
        return out
    }

    /** The innermost target at [offset], so a hint inside an option line wins over the option. */
    fun at(text: CharSequence, offset: Int): TapSpan? {
        if (text !is Spanned) return null
        return text.getSpans(offset, offset, TapSpan::class.java)
            .filter { text.getSpanStart(it) <= offset && offset < text.getSpanEnd(it) }
            .minByOrNull { text.getSpanEnd(it) - text.getSpanStart(it) }
    }
}
