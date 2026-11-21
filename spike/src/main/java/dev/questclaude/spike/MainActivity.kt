package dev.questclaude.spike

import android.app.Activity
import android.content.Intent
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/**
 * Answers one question: can this app, at targetSdk 34 and with no Termux, run proot and an
 * Ubuntu rootfs it unpacked itself? Runs the checks on launch and logs everything to the
 * screen, logcat (tag QCSpike) and /sdcard/Android/data/dev.questclaude.spike/files/spike.log.
 *
 * Drive it over adb: `am start -n dev.questclaude.spike/.MainActivity -e cmd 'apt-get update'`
 * runs a command inside Ubuntu (after any running one finishes).
 */
class MainActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var out: TextView
    private lateinit var scroll: ScrollView
    @Volatile private var current: Process? = null

    private val libDir by lazy { applicationInfo.nativeLibraryDir }
    private val rootfs by lazy { File(filesDir, "ubuntu") }
    private val logFile by lazy { File(getExternalFilesDir(null), "spike.log") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        buildUi()
        if (savedInstanceState == null) {
            logFile.delete()
            runChecks()
        }
        handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    private fun handle(intent: Intent?) {
        intent?.getStringExtra("cmd")?.let { cmd -> worker.execute { step("cmd: $cmd") { proot(cmd) } } }
        if (intent?.getBooleanExtra("checks", false) == true) runChecks()
        if (intent?.getBooleanExtra("wipe", false) == true) wipe()
    }

    // ---- checks ----

    private fun runChecks() = worker.execute {
        log("== device: Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT}), " +
            "targetSdk ${applicationInfo.targetSdkVersion}, ${Build.MANUFACTURER} ${Build.MODEL}, " +
            "ABIs ${Build.SUPPORTED_ABIS.joinToString()}")
        log("nativeLibraryDir $libDir: " + (File(libDir).list()?.sorted()?.joinToString() ?: "(unreadable)"))
        val results = linkedMapOf<String, Boolean>()
        results["exec from nativeLibraryDir"] = step("1. exec libproot.so --version from nativeLibraryDir") {
            run(listOf("$libDir/libproot.so", "--version"))
        }
        results["unpack rootfs"] = step("2. unpack the Ubuntu rootfs into filesDir") { unpack(); 0 }
        // Control: shows W^X is really in force, so a pass in 4 means proot got around it. Uses a
        // copy of the static loader, since Ubuntu's own binaries would fail on the missing glibc
        // ld-linux (ENOENT) whatever the policy.
        step("3. control: exec a copy of the static loader from filesDir (W^X should refuse)") {
            val copy = File(filesDir, "loader-copy")
            File("$libDir/libproot-loader.so").copyTo(copy, overwrite = true)
            copy.setExecutable(true)
            try {
                val code = run(listOf(copy.path))
                log("   exec WORKED (exit $code): W^X isn't enforced here"); 1
            } catch (e: IOException) {
                log("   refused as expected: ${e.message}"); 0
            }
        }
        results["proot runs Ubuntu binaries"] = step("4. proot: uname, id, os-release") {
            proot("uname -a; id; grep PRETTY /etc/os-release")
        }
        results["dpkg works"] = step("5. proot: dpkg + a pipeline") {
            proot("dpkg --print-architecture && ls /usr/bin | wc -l && echo pipeline-ok")
        }
        log("== SPIKE RESULT: " + results.entries.joinToString("; ") { (k, v) -> "$k ${if (v) "PASS" else "FAIL"}" })
        log("   next: tap apt-get update (network + package manager), then try the command box")
    }

    /** Logs [title], runs [block] (an exit code), logs PASS/FAIL with timing. */
    private fun step(title: String, block: () -> Int): Boolean {
        log("-- $title")
        val t0 = SystemClock.elapsedRealtime()
        val ok = try {
            val code = block()
            log("   exit $code")
            code == 0
        } catch (e: Exception) {
            log("   ${e.javaClass.simpleName}: ${e.message}")
            false
        }
        log("   ${if (ok) "PASS" else "FAIL"} in ${SystemClock.elapsedRealtime() - t0} ms")
        return ok
    }

    // ---- processes ----

    private fun baseEnv() = mapOf(
        "LD_LIBRARY_PATH" to libDir,
        // Termux's proot has its loader path baked in under com.termux; point it at ours.
        "PROOT_LOADER" to "$libDir/libproot-loader.so",
        "PROOT_TMP_DIR" to cacheDir.path,
        "TMPDIR" to cacheDir.path,
        "PATH" to "/system/bin",
    )

    /** Runs [cmd] with `sh -c` inside Ubuntu, the way proot-distro's `login` does. */
    private fun proot(cmd: String): Int {
        val r = rootfs.path
        return run(
            listOf(
                "$libDir/libproot.so",
                "--kill-on-exit", "--link2symlink", "--sysvipc", "-L",
                "--kernel-release=6.2.1-PRoot-Spike",
                "-0", "-r", r, "-w", "/root",
                "-b", "/dev", "-b", "/proc", "-b", "/sys", "-b", "$r/tmp:/dev/shm",
                "/usr/bin/env", "-i",
                "HOME=/root", "USER=root", "LANG=C.UTF-8", "TERM=xterm-256color", "TMPDIR=/tmp",
                "DEBIAN_FRONTEND=noninteractive",
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "/bin/sh", "-c", cmd,
            ),
            env = baseEnv(),
        )
    }

    /** Runs [argv], streaming stdout+stderr into the log. Throws if exec itself fails. */
    private fun run(argv: List<String>, env: Map<String, String> = baseEnv()): Int {
        val pb = ProcessBuilder(argv).redirectErrorStream(true).directory(filesDir)
        pb.environment().clear()
        pb.environment().putAll(env)
        val p = pb.start()
        current = p
        try {
            p.outputStream.close()
            p.inputStream.bufferedReader().forEachLine { log("   | $it") }
            return p.waitFor()
        } finally {
            current = null
        }
    }

    // ---- rootfs ----

    private fun unpack() {
        val marker = File(rootfs, ".spike-unpacked")
        if (marker.exists()) { log("   already unpacked"); return }
        rmTree(rootfs)
        rootfs.mkdirs()
        val name = try { assets.open("rootfs.txt").bufferedReader().readText().trim() } catch (e: IOException) { "?" }
        log("   $name")
        val dirModes = mutableListOf<Pair<File, Int>>()
        var files = 0; var links = 0; var hard = 0; var hardCopied = 0; var skipped = 0
        TarArchiveInputStream(GZIPInputStream(BufferedInputStream(assets.open("rootfs.tar.gz"), 1 shl 16))).use { tar ->
            while (true) {
                val e = tar.nextEntry ?: break
                val f = File(rootfs, e.name)
                // Always keep owner rw(x): the kernel checks our real uid, and apt must be able
                // to replace "root-owned" read-only files later.
                val mode = e.mode and "7777".toInt(8)
                when {
                    e.isDirectory -> { f.mkdirs(); dirModes += f to (mode or "700".toInt(8)) }
                    e.isSymbolicLink -> {
                        f.parentFile?.mkdirs(); f.delete()
                        Os.symlink(e.linkName, f.path); links++
                    }
                    e.isLink -> {
                        f.parentFile?.mkdirs(); f.delete()
                        val target = File(rootfs, e.linkName)
                        try { Os.link(target.path, f.path); hard++ }
                        catch (x: ErrnoException) { target.copyTo(f, overwrite = true); Os.chmod(f.path, mode or "600".toInt(8)); hardCopied++ }
                    }
                    e.isFile -> {
                        f.parentFile?.mkdirs()
                        f.outputStream().use { tar.copyTo(it) }
                        Os.chmod(f.path, mode or "600".toInt(8)); files++
                    }
                    else -> skipped++
                }
            }
        }
        dirModes.forEach { (d, m) -> Os.chmod(d.path, m) }
        // DNS: Android has no resolv.conf to share, and Ubuntu's points at systemd-resolved.
        File(rootfs, "etc/resolv.conf").let { it.delete(); it.writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n") }
        File(rootfs, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")
        // apt drops to the _apt user to download, which proot's fake root can't do.
        File(rootfs, "etc/apt/apt.conf.d/99-proot").writeText("APT::Sandbox::User \"root\";\n")
        marker.writeText(name)
        log("   $files files, $links symlinks, $hard hardlinks ($hardCopied copied instead), $skipped other entries skipped")
    }

    /** Deletes [f] and, for a real directory, everything in it. Never follows symlinks. */
    private fun rmTree(f: File) {
        val st = try { Os.lstat(f.path) } catch (e: ErrnoException) { return }
        if (OsConstants.S_ISDIR(st.st_mode)) {
            try { Os.chmod(f.path, "700".toInt(8)) } catch (_: ErrnoException) {}
            f.list()?.forEach { rmTree(File(f, it)) }
        }
        f.delete()
    }

    private fun wipe() = worker.execute { step("wipe rootfs") { rmTree(rootfs); if (rootfs.exists()) 1 else 0 } }

    // ---- UI ----

    private fun buildUi() {
        val pad = (12 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(pad, pad, pad, pad) }
        val bar = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun button(label: String, onTap: () -> Unit) =
            Button(this).apply { text = label; isAllCaps = false; setOnClickListener { onTap() } }.also { bar.addView(it) }
        button("Run checks") { runChecks() }
        button("apt-get update") { worker.execute { step("apt-get update") { proot("apt-get update") } } }
        button("Stop") { current?.destroy() }
        button("Wipe rootfs") { wipe() }
        button("Clear") { out.text = "" }
        root.addView(bar)

        val cmdRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val cmd = EditText(this).apply {
            hint = "command to run inside Ubuntu"; setSingleLine(); typeface = Typeface.MONOSPACE
        }
        cmdRow.addView(cmd, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        cmdRow.addView(Button(this).apply {
            text = "Run"; isAllCaps = false
            setOnClickListener {
                val c = cmd.text.toString().trim()
                if (c.isNotEmpty()) worker.execute { step("cmd: $c") { proot(c) } }
            }
        })
        root.addView(cmdRow)

        out = TextView(this).apply {
            typeface = Typeface.MONOSPACE; textSize = 13f; setTextIsSelectable(true)
        }
        scroll = ScrollView(this).apply { addView(out) }
        root.addView(scroll, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        setContentView(root)
    }

    private fun log(line: String) {
        Log.i("QCSpike", line)
        try { logFile.appendText(line + "\n") } catch (_: IOException) {}
        ui.post {
            out.append(line + "\n")
            if (out.length() > 200_000) out.text = out.text.subSequence(out.length() - 150_000, out.length())
            scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
        }
    }
}
