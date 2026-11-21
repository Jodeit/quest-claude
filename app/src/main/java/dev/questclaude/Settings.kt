package dev.questclaude

import android.content.Context

class Settings(ctx: Context) {
    private val prefs = ctx.getSharedPreferences("qc", Context.MODE_PRIVATE)

    var session: String
        get() = prefs.getString("session", "claude")!!
        set(v) = prefs.edit().putString("session", v.trim().ifEmpty { "claude" }).apply()

    var launchCommand: String
        get() = prefs.getString("launch", DEFAULT_LAUNCH)!!
        set(v) = prefs.edit().putString("launch", v.trim().ifEmpty { DEFAULT_LAUNCH }).apply()

    var reconnectCommand: String
        get() = prefs.getString("reconnect", DEFAULT_RECONNECT)!!
        set(v) = prefs.edit().putString("reconnect", v.trim().ifEmpty { DEFAULT_RECONNECT }).apply()

    var remoteCommand: String
        get() = prefs.getString("remote", DEFAULT_REMOTE)!!
        set(v) = prefs.edit().putString("remote", v.trim().ifEmpty { DEFAULT_REMOTE }).apply()

    companion object {
        const val DEFAULT_LAUNCH = "proot-distro login ubuntu -- bash -lc 'cd ~ && claude'"
        /** `quest up` finds the Wireless debugging port, reopens adb on 5555 and re-applies keep-awake. */
        const val DEFAULT_RECONNECT = "proot-distro login ubuntu -- bash -lc 'quest up'"
        const val DEFAULT_REMOTE = "proot-distro login ubuntu -- bash -lc 'cd ~ && claude remote-control'"
        const val REMOTE_SESSION = "claude-rc"
    }
}
