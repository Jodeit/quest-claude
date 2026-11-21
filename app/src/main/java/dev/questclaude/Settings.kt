package dev.questclaude

import android.content.Context

class Settings(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("qc", Context.MODE_PRIVATE)

    var session: String
        get() = prefs.getString("session", DEFAULT_SESSION)!!
        set(v) = prefs.edit().putString("session", v.trim().ifEmpty { DEFAULT_SESSION }).apply()

    var launchCommand: String
        get() = prefs.getString("launch", DEFAULT_LAUNCH)!!
        set(v) = prefs.edit().putString("launch", v.trim().ifEmpty { DEFAULT_LAUNCH }).apply()

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

    companion object {
        const val DEFAULT_SESSION = "claude"
        const val DEFAULT_LAUNCH = "proot-distro login ubuntu -- bash -lc 'cd ~ && claude'"
        /** `quest up` finds the Wireless debugging port, reopens adb on 5555 and re-applies keep-awake. */
        const val DEFAULT_RECONNECT = "proot-distro login ubuntu -- bash -lc 'quest up'"
    }
}
