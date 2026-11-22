package dev.cwaude

import android.content.Context
import android.util.AttributeSet
import android.view.ViewGroup

/**
 * The tab strip: children left to right, wrapping onto another row when the next one doesn't
 * fit, so every tab stays whole and visible (no sideways scrolling). Rows are bottom-aligned,
 * and the last row sits flush on the terminal so the active tab can run into it. Children's
 * start/end margins space them horizontally; [rowGap] separates rows.
 */
class TabFlow(ctx: Context, attrs: AttributeSet?) : ViewGroup(ctx, attrs) {
    private val rowGap = (4 * resources.displayMetrics.density).toInt()

    override fun generateDefaultLayoutParams() =
        MarginLayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT)
    override fun generateLayoutParams(attrs: AttributeSet?) = MarginLayoutParams(context, attrs)
    override fun generateLayoutParams(p: LayoutParams?) = MarginLayoutParams(p)
    override fun checkLayoutParams(p: LayoutParams?) = p is MarginLayoutParams

    /** Each row: (first child index, end index exclusive, row height). */
    private val rows = mutableListOf<Triple<Int, Int, Int>>()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val avail = MeasureSpec.getSize(widthMeasureSpec) - paddingLeft - paddingRight
        rows.clear()
        var start = 0; var x = 0; var rowH = 0; var widest = 0
        for (i in 0 until childCount) {
            val c = getChildAt(i)
            if (c.visibility == GONE) continue
            // A tab may be at most a full row wide; its own maxWidths usually keep it far below.
            measureChildWithMargins(c, MeasureSpec.makeMeasureSpec(avail, MeasureSpec.AT_MOST), 0,
                heightMeasureSpec, 0)
            val lp = c.layoutParams as MarginLayoutParams
            val w = c.measuredWidth + lp.marginStart + lp.marginEnd
            if (x > 0 && x + w > avail) {
                rows += Triple(start, i, rowH)
                start = i; x = 0; rowH = 0
            }
            x += w
            widest = maxOf(widest, x)
            rowH = maxOf(rowH, c.measuredHeight + lp.topMargin + lp.bottomMargin)
        }
        if (start < childCount) rows += Triple(start, childCount, rowH)
        val h = rows.sumOf { it.third } + rowGap * (rows.size - 1).coerceAtLeast(0)
        setMeasuredDimension(
            resolveSize(widest + paddingLeft + paddingRight, widthMeasureSpec),
            resolveSize(h + paddingTop + paddingBottom, heightMeasureSpec))
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        var y = paddingTop
        for ((start, end, rowH) in rows) {
            var x = paddingLeft
            for (i in start until end) {
                val c = getChildAt(i)
                if (c.visibility == GONE) continue
                val lp = c.layoutParams as MarginLayoutParams
                x += lp.marginStart
                val top = y + rowH - lp.bottomMargin - c.measuredHeight // bottom-aligned
                c.layout(x, top, x + c.measuredWidth, top + c.measuredHeight)
                x += c.measuredWidth + lp.marginEnd
            }
            y += rowH + rowGap
        }
    }
}
