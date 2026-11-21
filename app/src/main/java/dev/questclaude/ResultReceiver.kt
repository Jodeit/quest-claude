package dev.questclaude

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Bundle

/** Receives RUN_COMMAND results from Termux and forwards errors to the UI. */
class ResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val label = intent.getStringExtra(EXTRA_LABEL) ?: "cmd"
        @Suppress("DEPRECATION")
        val r: Bundle = intent.getBundleExtra("result") ?: return
        val exit = r.getInt("exitCode", 0)
        val err = r.getInt("err", -1)
        val msg = listOf(r.getString("errmsg"), r.getString("stderr"))
            .filterNot { it.isNullOrBlank() }.joinToString(" · ").trim()
        listener?.invoke(label, exit == 0 && err <= -1, if (msg.isEmpty()) "exit $exit" else msg)
    }

    companion object {
        const val EXTRA_LABEL = "label"
        /** Set by MainActivity while it is visible. */
        @Volatile var listener: ((label: String, ok: Boolean, message: String) -> Unit)? = null
    }
}
