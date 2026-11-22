package dev.cwaude

import android.content.Context

class Settings(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("cwaude", Context.MODE_PRIVATE)

    /** The tab on screen (a tmux session name). */
    var session: String
        get() = prefs.getString("session", DEFAULT_SESSION)!!
        set(v) = prefs.edit().putString("session", v.trim().ifEmpty { DEFAULT_SESSION }).apply()

    /** What a new home tab runs, inside Ubuntu (via `bash -lc`). */
    var launchCommand: String
        get() = prefs.getString("launch", DEFAULT_LAUNCH)!!
        set(v) = prefs.edit().putString("launch", v.trim().ifEmpty { DEFAULT_LAUNCH }).apply()

    /** What Reconnect runs, inside Ubuntu (via `bash -lc`). */
    var reconnectCommand: String
        get() = prefs.getString("reconnect", DEFAULT_RECONNECT)!!
        set(v) = prefs.edit().putString("reconnect", v.trim().ifEmpty { DEFAULT_RECONNECT }).apply()

    /** Last project picked for a new tab ("~ (home)" or a folder name in ~). */
    var lastProject: String
        get() = prefs.getString("last_project", "")!!
        set(v) = prefs.edit().putString("last_project", v).apply()

    /** Whether new tabs on a git repo get their own worktree. */
    var isolateTabs: Boolean
        get() = prefs.getBoolean("isolate_tabs", true)
        set(v) = prefs.edit().putBoolean("isolate_tabs", v).apply()

    /** Whether the key dock under the terminal is out (it's hidden to start with). */
    var showKeys: Boolean
        get() = prefs.getBoolean("show_keys", false)
        set(v) = prefs.edit().putBoolean("show_keys", v).apply()

    /** Tabs open in the last run, oldest first, so [Restore] can bring them back. */
    var openTabs: List<String>
        get() = prefs.getString("open_tabs", "")!!.split('\n').filter { it.isNotEmpty() }
        set(v) = prefs.edit().putString("open_tabs", v.joinToString("\n")).apply()

    /** When the current run's tmux server started (ms); Claudes started before it are older runs'. */
    var serverStartedAt: Long
        get() = prefs.getLong("server_started_at", 0L)
        set(v) = prefs.edit().putLong("server_started_at", v).apply()

    companion object {
        const val DEFAULT_SESSION = "claude"
        const val DEFAULT_LAUNCH = "cd ~ && claude"
        /** `quest up` finds the Wireless debugging port, reopens adb on 5555 and re-applies keep-awake. */
        const val DEFAULT_RECONNECT = "quest up"
    }
}
