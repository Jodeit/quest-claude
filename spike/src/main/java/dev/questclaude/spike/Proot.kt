package dev.questclaude.spike

import android.content.Context
import android.util.Log
import java.io.File
import java.io.IOException

/** Launches commands inside the app's own Ubuntu, the way proot-distro's `login` does. */
object Proot {
    fun rootfs(ctx: Context) = File(ctx.filesDir, "ubuntu")
    fun unpacked(ctx: Context) = File(rootfs(ctx), ".spike-unpacked").exists()

    /** Environment for proot itself (not the guest), pointing it at our renamed binaries. */
    fun hostEnv(ctx: Context): Map<String, String> {
        val lib = ctx.applicationInfo.nativeLibraryDir
        return mapOf(
            "LD_LIBRARY_PATH" to lib,
            // Termux's proot has its loader path baked in under com.termux; point it at ours.
            "PROOT_LOADER" to "$lib/libproot-loader.so",
            "PROOT_TMP_DIR" to ctx.cacheDir.path,
            "TMPDIR" to ctx.cacheDir.path,
            "PATH" to "/system/bin",
        )
    }

    /**
     * `sh -c cmd` inside Ubuntu; [args] become $1, $2, ... With [killOnExit] (the default) every
     * process started inside dies when [cmd] exits; without it, proot lives as long as any of
     * them does, which is how the tmux server outlives the command that started it.
     */
    fun builder(ctx: Context, cmd: String, vararg args: String, killOnExit: Boolean = true): ProcessBuilder {
        val lib = ctx.applicationInfo.nativeLibraryDir
        val r = rootfs(ctx).path
        val argv = mutableListOf("$lib/libproot.so")
        if (killOnExit) argv += "--kill-on-exit"
        argv += listOf(
            "--link2symlink", "--sysvipc", "-L", "--kernel-release=6.2.1-PRoot-Spike",
            "-0", "-r", r, "-w", "/root",
            "-b", "/dev", "-b", "/proc", "-b", "/sys", "-b", "$r/tmp:/dev/shm",
            "/usr/bin/env", "-i",
            "HOME=/root", "USER=root", "LANG=C.UTF-8", "TERM=xterm-256color", "TMPDIR=/tmp",
            "DEBIAN_FRONTEND=noninteractive",
            "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "/bin/sh", "-c", cmd, "qc",
        )
        argv += args
        val pb = ProcessBuilder(argv).redirectErrorStream(true).directory(ctx.filesDir)
        pb.environment().clear()
        pb.environment().putAll(hostEnv(ctx))
        return pb
    }

    /** Runs [pb] to completion, passing each output line to [line]. Throws if exec fails. */
    fun run(pb: ProcessBuilder, line: (String) -> Unit): Int {
        val p = pb.start()
        p.outputStream.close()
        p.inputStream.bufferedReader().forEachLine(line)
        return p.waitFor()
    }
}

/** Shared log: logcat (tag QCSpike) plus spike.log on external storage, readable over adb. */
object SpikeLog {
    @Volatile private var file: File? = null

    fun init(ctx: Context, fresh: Boolean) {
        val f = File(ctx.getExternalFilesDir(null), "spike.log")
        if (fresh) f.delete()
        file = f
    }

    fun log(line: String) {
        Log.i("QCSpike", line)
        try { file?.appendText(line + "\n") } catch (_: IOException) {}
    }
}
