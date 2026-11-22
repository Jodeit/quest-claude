package dev.cwaude

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Brings tabs back after Qlaude's process dies (an APK update, a crash, a reboot). Android
 * kills everything the app started when that happens, tmux and every Claude with it; Quest
 * Claude never hit this because its tmux lived in Termux.
 *
 * Each running Claude keeps ~/.claude/sessions/<pid>.json with its session ID, cwd and tmux
 * pane ("name:@0.%0"). A Claude that exits normally removes its file; a killed one leaves it.
 * So when the tmux server has to start again, the files left from the last run, for tabs that
 * were still open, say which conversation each tab had, and `claude --resume` reopens it.
 */
object Restore {
    private const val TAG = "Cwaude"

    data class Tab(val name: String, val cwd: String, val sessionId: String)

    /**
     * Tabs to recreate: of [openTabs] (in that order), each with the Claude it last ran, if that
     * Claude started after [since] and has a conversation on disk to resume.
     */
    fun plan(ctx: Context, openTabs: List<String>, since: Long): List<Tab> {
        if (openTabs.isEmpty() || since <= 0) return emptyList()
        val home = File(Ubuntu.rootfs(ctx), "root/.claude")
        val latest = HashMap<String, Pair<Long, Tab>>()
        File(home, "sessions").listFiles { f -> f.name.endsWith(".json") }.orEmpty().forEach { f ->
            val j = runCatching { JSONObject(f.readText()) }.getOrNull() ?: return@forEach
            val name = j.optString("tmux").substringBefore(':')
            val id = j.optString("sessionId")
            val cwd = j.optString("cwd")
            if (name.isEmpty() || id.isEmpty() || cwd.isEmpty()) return@forEach
            if (j.optLong("startedAt") < since) return@forEach // an older run's
            val at = j.optLong("updatedAt", j.optLong("startedAt"))
            if ((latest[name]?.first ?: Long.MIN_VALUE) < at) latest[name] = at to Tab(name, cwd, id)
        }
        val projects = File(home, "projects").listFiles().orEmpty()
        return openTabs.mapNotNull { name ->
            val t = latest[name]?.second ?: return@mapNotNull null
            // Nothing said yet means nothing to resume (and --resume would fail): a fresh Claude.
            val said = projects.any { File(it, t.sessionId + ".jsonl").exists() }
            if (!File(Ubuntu.rootfs(ctx), t.cwd.removePrefix("/")).isDirectory) return@mapNotNull null
            if (said) t else t.copy(sessionId = "")
        }
    }

    /** Shell command that reopens [t]'s conversation in its folder. */
    fun launch(t: Tab) =
        "cd " + Tmux.shq(t.cwd) + " && claude" + (if (t.sessionId.isEmpty()) "" else " --resume " + Tmux.shq(t.sessionId))

    /** Creates [tabs] as detached tmux sessions; the server must be up. */
    fun create(ctx: Context, tabs: List<Tab>) {
        if (tabs.isEmpty()) return
        val script = StringBuilder()
        val args = mutableListOf<String>()
        tabs.forEach { t ->
            val n = args.size
            script.append("tmux new-session -d -s \"\$${n + 1}\" -x ${Tmux.COLS} -y ${Tmux.ROWS} bash -lc \"\$${n + 2}\"; ")
            args += t.name
            args += Tmux.launchScript(launch(t))
        }
        val (code, out) = Ubuntu.capture(ctx, script.toString(), *args.toTypedArray())
        Log.i(TAG, "restored ${tabs.map { it.name }} (exit $code) ${out.trim()}")
    }
}
