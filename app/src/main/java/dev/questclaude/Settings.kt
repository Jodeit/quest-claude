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

    var submitOnSend: Boolean
        get() = prefs.getBoolean("submit", true)
        set(v) = prefs.edit().putBoolean("submit", v).apply()

    companion object {
        const val DEFAULT_LAUNCH = "proot-distro login ubuntu -- bash -lc 'cd ~ && claude'"
    }
}
