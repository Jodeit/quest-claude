package dev.cwaude

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings as SysSettings
import android.util.Log

/**
 * Turns Wireless debugging back on, which Android switches off at every boot. This replaces
 * tapping Start in Shizuku: `quest up` then finds the port and reopens 127.0.0.1:5555.
 *
 * Needs WRITE_SECURE_SETTINGS, which only adb can grant:
 *   adb shell pm grant dev.questclaude android.permission.WRITE_SECURE_SETTINGS
 * (scripts/install.sh does this).
 */
object WirelessDebugging {
    private const val KEY = "adb_wifi_enabled"
    private const val PERM = "android.permission.WRITE_SECURE_SETTINGS"

    fun canEnable(ctx: Context): Boolean =
        ctx.checkSelfPermission(PERM) == PackageManager.PERMISSION_GRANTED

    fun isOn(ctx: Context): Boolean =
        SysSettings.Global.getInt(ctx.contentResolver, KEY, 0) == 1

    /** Returns true if it is on afterwards. */
    fun enable(ctx: Context): Boolean {
        if (isOn(ctx)) return true
        if (!canEnable(ctx)) return false
        return try {
            SysSettings.Global.putInt(ctx.contentResolver, KEY, 1)
            Log.i("Cwaude", "turned Wireless debugging on")
            true
        } catch (e: SecurityException) {
            Log.w("Cwaude", "couldn't turn Wireless debugging on", e)
            false
        }
    }
}

/** Re-enables Wireless debugging after a reboot. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_LOCKED_BOOT_COMPLETED
        ) WirelessDebugging.enable(ctx)
    }
}
