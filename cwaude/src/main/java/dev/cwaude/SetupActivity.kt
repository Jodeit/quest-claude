package dev.cwaude

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.concurrent.thread

/**
 * First run: unpack Ubuntu, install packages and Claude Code. Everything Termux, proot-distro
 * and scripts/setup.sh did by hand for Quest Claude. Opens the main screen when done.
 */
class SetupActivity : Activity() {
    private lateinit var log: TextView
    private lateinit var scroll: ScrollView
    private lateinit var retry: Button
    @Volatile private var running = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = dp(24)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, pad)
            setBackgroundColor(getColor(R.color.bg))
        }
        root.addView(TextView(this).apply {
            text = "Setting up Qlaude"; textSize = 24f; setTypeface(typeface, Typeface.BOLD)
            setTextColor(getColor(R.color.accent))
        })
        root.addView(TextView(this).apply {
            text = "Qlaude, a Quest Claude Code app, runs Claude Code in its own Ubuntu, right here on the headset. The first start " +
                "unpacks Ubuntu and downloads its packages and Claude Code (a few minutes, a few hundred MB). " +
                "Keep this window open."
            textSize = 15f; setTextColor(getColor(R.color.fg)); setPadding(0, dp(8), 0, dp(12))
        })
        log = TextView(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 12f; setTextColor(getColor(R.color.muted))
            setTextIsSelectable(true)
        }
        scroll = ScrollView(this).apply {
            setBackgroundColor(getColor(R.color.term_bg)); setPadding(dp(8), dp(8), dp(8), dp(8)); addView(log)
        }
        root.addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        retry = Button(this).apply {
            text = "Try again"; isAllCaps = false; visibility = android.view.View.GONE
            setOnClickListener { start() }
        }
        root.addView(retry, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
        setContentView(root)
        start()
    }

    private fun start() {
        if (running) return
        running = true
        retry.visibility = android.view.View.GONE
        thread(name = "setup") {
            val ok = try {
                Ubuntu.unpack(this) { line(it) }
                line("")
                val code = Ubuntu.provision(this) { line(it) }
                if (code != 0) line("✗ setup stopped (exit $code). Check the network and try again.")
                code == 0
            } catch (e: Exception) {
                Log.w("Cwaude", "setup failed", e)
                line("✗ ${e.javaClass.simpleName}: ${e.message}")
                false
            }
            running = false
            runOnUiThread {
                if (ok) {
                    startActivity(Intent(this, MainActivity::class.java))
                    finish()
                } else retry.visibility = android.view.View.VISIBLE
            }
        }
    }

    private fun line(s: String) {
        Log.i("Cwaude", "setup: $s")
        runOnUiThread {
            log.append(s + "\n")
            if (log.length() > 100_000) log.text = log.text.subSequence(log.length() - 80_000, log.length())
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
}
