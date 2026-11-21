package dev.cwaude

import android.graphics.Color
import android.graphics.Typeface
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.text.style.UnderlineSpan

/**
 * Renders `tmux capture-pane -e` output (text with SGR escapes) as styled text, so the mirror
 * shows Claude's colors and its inverse-video cursor.
 */
class Ansi(private val defaultFg: Int, private val defaultBg: Int) {

    private data class Style(
        val fg: Int? = null, val bg: Int? = null,
        val bold: Boolean = false, val dim: Boolean = false, val italic: Boolean = false,
        val underline: Boolean = false, val inverse: Boolean = false,
    )

    /**
     * @param cursor (column, row) to draw as a block cursor, or null when the program hides the
     *   terminal cursor (Claude Code does, and draws its own).
     */
    fun render(src: String, cursor: Pair<Int, Int>?): CharSequence {
        val out = SpannableStringBuilder()
        var style = Style()
        var runStart = 0
        var row = 0
        var col = 0
        var cursorAt = -1

        fun flush() {
            if (out.length > runStart) apply(out, runStart, out.length, style)
            runStart = out.length
        }

        var i = 0
        while (i < src.length) {
            val c = src[i]
            if (c == '\u001b' && i + 1 < src.length) {
                when (src[i + 1]) {
                    '[' -> { // CSI ... final byte
                        var j = i + 2
                        while (j < src.length && src[j] !in '@'..'~') j++
                        if (j < src.length && src[j] == 'm') {
                            flush()
                            style = sgr(style, src.substring(i + 2, j))
                        }
                        i = j + 1
                    }
                    ']' -> { // OSC (e.g. hyperlinks) ... BEL or ESC \
                        var j = i + 2
                        while (j < src.length && src[j] != '\u0007' &&
                            !(src[j] == '\u001b' && j + 1 < src.length && src[j + 1] == '\\')) j++
                        i = if (j < src.length && src[j] == '\u0007') j + 1 else j + 2
                    }
                    else -> i += 2
                }
                continue
            }
            if (cursor != null && row == cursor.second && col == cursor.first && c != '\n') {
                cursorAt = out.length
            }
            if (c == '\n') {
                if (cursor != null && row == cursor.second && cursorAt < 0) {
                    // Cursor sits past the end of the line's text: pad out to it.
                    flush()
                    while (col < cursor.first) { out.append(' '); col++ }
                    runStart = out.length
                    cursorAt = out.length
                    out.append(' ')
                    runStart = out.length
                }
                row++; col = 0
            } else col++
            out.append(c)
            i++
        }
        flush()
        if (cursor != null && cursorAt < 0 && row == cursor.second) { // cursor past the last line's end
            while (col < cursor.first) { out.append(' '); col++ }
            cursorAt = out.length
            out.append(' ')
        }
        if (cursorAt in 0 until out.length) {
            out.setSpan(BackgroundColorSpan(defaultFg), cursorAt, cursorAt + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            out.setSpan(ForegroundColorSpan(defaultBg), cursorAt, cursorAt + 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return out
    }

    private fun apply(out: SpannableStringBuilder, start: Int, end: Int, s: Style) {
        var fg = s.fg
        var bg = s.bg
        if (s.inverse) {
            val f = fg ?: defaultFg
            fg = bg ?: defaultBg
            bg = f
        }
        if (s.dim) fg = Color.argb(150, Color.red(fg ?: defaultFg), Color.green(fg ?: defaultFg), Color.blue(fg ?: defaultFg))
        val flag = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
        fg?.let { out.setSpan(ForegroundColorSpan(it), start, end, flag) }
        bg?.let { out.setSpan(BackgroundColorSpan(it), start, end, flag) }
        val tf = when {
            s.bold && s.italic -> Typeface.BOLD_ITALIC
            s.bold -> Typeface.BOLD
            s.italic -> Typeface.ITALIC
            else -> Typeface.NORMAL
        }
        if (tf != Typeface.NORMAL) out.setSpan(StyleSpan(tf), start, end, flag)
        if (s.underline) out.setSpan(UnderlineSpan(), start, end, flag)
    }

    private fun sgr(start: Style, params: String): Style {
        val p = if (params.isEmpty()) listOf(0) else params.split(';', ':').map { it.toIntOrNull() ?: 0 }
        var s = start
        var k = 0
        while (k < p.size) {
            when (val n = p[k]) {
                0 -> s = Style()
                1 -> s = s.copy(bold = true)
                2 -> s = s.copy(dim = true)
                3 -> s = s.copy(italic = true)
                4 -> s = s.copy(underline = true)
                7 -> s = s.copy(inverse = true)
                22 -> s = s.copy(bold = false, dim = false)
                23 -> s = s.copy(italic = false)
                24 -> s = s.copy(underline = false)
                27 -> s = s.copy(inverse = false)
                in 30..37 -> s = s.copy(fg = PALETTE[n - 30])
                in 90..97 -> s = s.copy(fg = PALETTE[n - 90 + 8])
                in 40..47 -> s = s.copy(bg = PALETTE[n - 40])
                in 100..107 -> s = s.copy(bg = PALETTE[n - 100 + 8])
                39 -> s = s.copy(fg = null)
                49 -> s = s.copy(bg = null)
                38, 48 -> {
                    var color: Int? = null
                    if (p.getOrNull(k + 1) == 5 && k + 2 < p.size) {
                        color = xterm256(p[k + 2]); k += 2
                    } else if (p.getOrNull(k + 1) == 2 && k + 4 < p.size) {
                        color = Color.rgb(p[k + 2], p[k + 3], p[k + 4]); k += 4
                    }
                    s = if (n == 38) s.copy(fg = color) else s.copy(bg = color)
                }
            }
            k++
        }
        return s
    }

    companion object {
        private val PALETTE = intArrayOf(
            0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
            0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea,
        ).map { it or 0xFF000000.toInt() }.toIntArray()

        fun xterm256(n: Int): Int = when {
            n < 16 -> PALETTE[n.coerceAtLeast(0)]
            n < 232 -> {
                val v = n - 16
                fun lvl(x: Int) = if (x == 0) 0 else 55 + x * 40
                Color.rgb(lvl(v / 36), lvl(v / 6 % 6), lvl(v % 6))
            }
            else -> (8 + (n.coerceAtMost(255) - 232) * 10).let { Color.rgb(it, it, it) }
        }
    }
}
