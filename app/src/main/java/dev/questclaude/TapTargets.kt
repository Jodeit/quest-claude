package dev.questclaude

import android.text.SpannableStringBuilder
import android.graphics.Color
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.UnderlineSpan

/**
 * A tappable bit of Claude's UI: tapping it sends [key] (a tmux key name; several separated by
 * spaces are pressed in turn) or types [literal].
 */
class TapSpan(val key: String? = null, val literal: String? = null)

/**
 * Finds Claude's live controls in the pane and marks them tappable: numbered options in a
 * prompt ("❯ 1. Yes", "  2. No") and shortcut hints ("esc to interrupt", "Tab to amend",
 * "(shift+tab to cycle)"). Only text below the last full-width ─ rule counts: that's the top of
 * a dialog, or the bottom of the input box, so the transcript (which can mention "esc to
 * interrupt" or "1. Yes" too) and the prompt you're typing are never tappable.
 *
 * Two exceptions. A list split by a rule (a question's options, a rule, then "Chat about this")
 * counts from the rule above it. And Claude's grey suggested next prompt in the input box is
 * tappable: Tab accepts it, Enter sends it. Text you typed yourself isn't grey, so it never is.
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
        val rules = starts.indices.filter { RULE.matches(line(it)) }
        val lastRule = rules.lastOrNull() ?: return text
        if (lastRule == starts.lastIndex) return text
        val prevRule = rules.getOrNull(rules.size - 2)
        // Options start below the last rule, or the one before it if that stretch is a list (two
        // or more options; a prompt you typed as "1. foo" alone doesn't count).
        val optionsFrom = if (prevRule != null &&
            (prevRule + 1 until lastRule).count { OPTION.containsMatchIn(line(it)) } >= 2) prevRule else lastRule

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
        // The input box: the lines between the last two rules, starting "❯". Grey text in it is
        // Claude's suggestion (typed text is the default color, so has no color span).
        if (prevRule != null && line(prevRule + 1).trimStart().startsWith("❯") &&
            !OPTION.containsMatchIn(line(prevRule + 1))) {
            val from = starts[prevRule + 1] + line(prevRule + 1).indexOf('❯') + 1
            val to = starts[lastRule] - 1
            val chars = (from until to).filter { !s[it].isWhitespace() }
            // Skip the first: Claude draws its cursor there in inverse video.
            if (chars.size >= 2 && chars.drop(1).all { grey(text, it) }) {
                for (k in prevRule + 1 until lastRule) {
                    val l = line(k)
                    val a = if (k == prevRule + 1) l.indexOf('❯') + 1 else 0
                    val b = l.trimEnd().length
                    val lead = l.substring(a).length - l.substring(a).trimStart().length
                    span(starts[k] + a + lead, starts[k] + b, TapSpan(key = "Tab Enter"))
                }
            }
        }

        var n = optionsFrom + 1
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

    /** Drawn dim, or in a neutral grey: how Claude shows hints and suggestions. */
    private fun grey(text: CharSequence, at: Int): Boolean {
        if (text !is Spanned) return false
        val c = text.getSpans(at, at + 1, ForegroundColorSpan::class.java).lastOrNull()?.foregroundColor
            ?: return false
        val r = Color.red(c); val g = Color.green(c); val b = Color.blue(c)
        return Color.alpha(c) < 255 || (maxOf(r, g, b) - minOf(r, g, b) < 16 && r in 80..190)
    }

    /** The innermost target at [offset], so a hint inside an option line wins over the option. */
    fun at(text: CharSequence, offset: Int): TapSpan? {
        if (text !is Spanned) return null
        return text.getSpans(offset, offset, TapSpan::class.java)
            .filter { text.getSpanStart(it) <= offset && offset < text.getSpanEnd(it) }
            .minByOrNull { text.getSpanEnd(it) - text.getSpanStart(it) }
    }
}
