package dev.cwaude

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.BufferedInputStream
import java.io.File

/**
 * Cwaude's own Ubuntu: a rootfs in the app's files dir, run through proot. proot and its
 * loader ship as lib*.so (see scripts/fetch-ubuntu-prebuilts.sh) because nativeLibraryDir is
 * the only place an app targeting SDK 29+ may exec from; proot then loads Ubuntu's binaries
 * itself, so nothing in the rootfs is ever exec'd directly.
 */
object Ubuntu {
    fun rootfs(ctx: Context) = File(ctx.filesDir, "ubuntu")
    private fun unpackedMarker(ctx: Context) = File(rootfs(ctx), ".cwaude-unpacked")
    private fun provisionedMarker(ctx: Context) = File(rootfs(ctx), "root/.cwaude/provisioned")

    fun unpacked(ctx: Context) = unpackedMarker(ctx).exists()
    /** Unpacked, packages and Claude Code installed: the app can start. */
    fun ready(ctx: Context) = unpacked(ctx) && provisionedMarker(ctx).exists()

    /** tmux's server socket, as seen from Android. */
    fun tmuxSocket(ctx: Context) = File(rootfs(ctx), "tmp/tmux-0/default")

    /** Environment for proot itself (not the guest), pointing it at our renamed binaries. */
    fun hostEnv(ctx: Context): Map<String, String> {
        val lib = ctx.applicationInfo.nativeLibraryDir
        return mapOf(
            "LD_LIBRARY_PATH" to lib,
            // Termux's proot build has its loader path baked in under com.termux; point it at ours.
            "PROOT_LOADER" to "$lib/libproot-loader.so",
            "PROOT_TMP_DIR" to ctx.cacheDir.path,
            "TMPDIR" to ctx.cacheDir.path,
            "PATH" to "/system/bin",
        )
    }

    /**
     * `sh -c cmd` inside Ubuntu; [args] become $1, $2, ... so text is never spliced into shell
     * source. With [killOnExit] everything started inside dies when [cmd] exits; without it,
     * proot lives as long as anything it started, which is how the tmux server stays up.
     */
    fun builder(ctx: Context, cmd: String, vararg args: String, killOnExit: Boolean = true): ProcessBuilder {
        val lib = ctx.applicationInfo.nativeLibraryDir
        // The canonical path (/data/data/<pkg>, not the /data/user/0 alias filesDir gives):
        // proot's hardlink emulation stores absolute host paths in its .l2s. symlinks, and only
        // maps them back into Ubuntu if they start with the rootfs as given here. With the alias,
        // anything dpkg had hardlinked (perl, so debconf and most apt installs) was unreachable.
        val r = rootfs(ctx).canonicalPath
        val argv = mutableListOf("$lib/libproot.so")
        if (killOnExit) argv += "--kill-on-exit"
        argv += listOf(
            "--link2symlink", "--sysvipc", "-L", "--kernel-release=6.2.1-PRoot-Cwaude",
            "-0", "-r", r, "-w", "/root",
            "-b", "/dev", "-b", "/proc", "-b", "/sys", "-b", "$r/tmp:/dev/shm",
            "/usr/bin/env", "-i",
            "HOME=/root", "USER=root", "LANG=C.UTF-8", "TERM=xterm-256color", "TMPDIR=/tmp",
            "PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            // Every Claude gets these via the tmux server's environment, whatever ~/.profile says.
            "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1", // conversation goes to tmux scrollback, which we mirror
            "ANDROID_SERIAL=127.0.0.1:5555",          // `quest` and adb talk to this headset
            "/bin/sh", "-c", cmd, "cw",
        )
        argv += args
        val pb = ProcessBuilder(argv).redirectErrorStream(true).directory(ctx.filesDir)
        pb.environment().clear()
        pb.environment().putAll(hostEnv(ctx))
        return pb
    }

    /** Runs [cmd] to completion, passing each output line to [line]. Throws if exec fails. */
    fun run(ctx: Context, cmd: String, vararg args: String, line: (String) -> Unit): Int {
        val p = builder(ctx, cmd, *args).start()
        p.outputStream.close()
        p.inputStream.bufferedReader().forEachLine(line)
        return p.waitFor()
    }

    /** Runs [cmd] and returns its exit code and output. */
    fun capture(ctx: Context, cmd: String, vararg args: String): Pair<Int, String> {
        val out = StringBuilder()
        val code = run(ctx, cmd, *args) { out.append(it).append('\n') }
        return code to out.toString()
    }

    /**
     * Once: point symlinks made while proot ran on the /data/user/0 alias at the canonical path
     * instead (see [builder]). Call before starting anything in Ubuntu.
     */
    fun fixLinks(ctx: Context) {
        val root = rootfs(ctx)
        val marker = File(root, "root/.cwaude/links-canonical")
        if (!unpacked(ctx) || marker.exists()) return
        val alias = root.absolutePath + "/"
        val real = root.canonicalPath + "/"
        if (alias == real) { marker.parentFile?.mkdirs(); marker.writeText(""); return }
        var fixed = 0
        java.nio.file.Files.walkFileTree(root.toPath(), object : java.nio.file.SimpleFileVisitor<java.nio.file.Path>() {
            override fun visitFile(f: java.nio.file.Path, a: java.nio.file.attribute.BasicFileAttributes): java.nio.file.FileVisitResult {
                if (a.isSymbolicLink) runCatching {
                    val t = Os.readlink(f.toString())
                    if (t.startsWith(alias)) {
                        File(f.toString()).delete()
                        Os.symlink(real + t.substring(alias.length), f.toString())
                        fixed++
                    }
                }
                return java.nio.file.FileVisitResult.CONTINUE
            }
            override fun visitFileFailed(f: java.nio.file.Path, e: java.io.IOException) = java.nio.file.FileVisitResult.CONTINUE
        })
        Log.i("Cwaude", "fixLinks: repointed $fixed symlinks from $alias to $real")
        marker.parentFile?.mkdirs()
        marker.writeText("$fixed\n")
    }

    // ---- First-run setup ----

    /** Unpacks the bundled Ubuntu base rootfs. Safe to call again; skips if already done. */
    fun unpack(ctx: Context, log: (String) -> Unit) {
        if (unpacked(ctx)) return
        val root = rootfs(ctx)
        deleteTree(root)
        root.mkdirs()
        val name = runCatching { ctx.assets.open("rootfs.txt").bufferedReader().readText().trim() }.getOrDefault("Ubuntu")
        log("Unpacking $name…")
        val dirModes = mutableListOf<Pair<File, Int>>()
        var entries = 0
        // AGP's asset merge gunzips *.gz and drops the extension, so it arrives as rootfs.tar.
        TarArchiveInputStream(BufferedInputStream(ctx.assets.open("rootfs.tar"), 1 shl 16)).use { tar ->
            while (true) {
                val e = tar.nextEntry ?: break
                val f = File(root, e.name)
                // Keep owner rw(x) on everything: the kernel checks our real uid, not proot's fake
                // root, and apt has to be able to replace "read-only" files later.
                val mode = e.mode and "7777".toInt(8)
                when {
                    e.isDirectory -> { f.mkdirs(); dirModes += f to (mode or "700".toInt(8)) }
                    e.isSymbolicLink -> { f.parentFile?.mkdirs(); f.delete(); Os.symlink(e.linkName, f.path) }
                    e.isLink -> { // hardlinks are refused in app storage: copy instead
                        f.parentFile?.mkdirs(); f.delete()
                        File(root, e.linkName).copyTo(f, overwrite = true)
                        Os.chmod(f.path, mode or "600".toInt(8))
                    }
                    e.isFile -> {
                        f.parentFile?.mkdirs()
                        f.outputStream().use { tar.copyTo(it) }
                        Os.chmod(f.path, mode or "600".toInt(8))
                    }
                }
                if (++entries % 500 == 0) log("  $entries files…")
            }
        }
        dirModes.forEach { (d, m) -> Os.chmod(d.path, m) }
        // Android has no resolv.conf to share, and Ubuntu's points at systemd-resolved.
        File(root, "etc/resolv.conf").let { it.delete(); it.writeText("nameserver 8.8.8.8\nnameserver 1.1.1.1\n") }
        File(root, "etc/hosts").writeText("127.0.0.1 localhost\n::1 localhost\n")
        // apt drops to the _apt user to download, which proot's fake root can't do.
        File(root, "etc/apt/apt.conf.d/99-proot").writeText("APT::Sandbox::User \"root\";\n")
        unpackedMarker(ctx).writeText(name)
        log("Unpacked $entries files.")
    }

    /**
     * Packages, Claude Code, and the shell and tmux settings Cwaude relies on. Safe to re-run.
     * Returns the script's exit code.
     */
    fun provision(ctx: Context, log: (String) -> Unit): Int = run(ctx, PROVISION, line = log)

    private val PROVISION = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        echo "Installing packages (a minute or two)…"
        apt-get update -q
        apt-get install -y -q --no-install-recommends \
          tmux git curl ca-certificates adb python3 python3-pil procps less nano unzip openssh-client
        if [ -e ~/.local/bin/claude ]; then echo "Claude Code is already installed."
        else echo "Installing Claude Code…"; curl -fsSL https://claude.ai/install.sh | bash; fi
        echo "Writing ~/.profile and ~/.tmux.conf…"
        grep -q 'cwaude:' ~/.profile 2>/dev/null || cat >> ~/.profile <<'EOF'
        # cwaude: claude on PATH, adb on this headset's loopback port, scrollback the app mirrors
        case ":${'$'}PATH:" in *":${'$'}HOME/.local/bin:"*) ;; *) PATH="${'$'}HOME/.local/bin:${'$'}PATH" ;; esac
        export ANDROID_SERIAL=127.0.0.1:5555
        export CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1
        EOF
        touch ~/.tmux.conf
        # The whole conversation as scrollback, and closing a tab moves to another one.
        grep -q history-limit ~/.tmux.conf || echo 'set -g history-limit 100000' >> ~/.tmux.conf
        grep -q detach-on-destroy ~/.tmux.conf || echo 'set -g detach-on-destroy off' >> ~/.tmux.conf
        mkdir -p ~/.cwaude && date > ~/.cwaude/provisioned
        echo "Done."
    """.trimIndent()

    /** Deletes [f] and, for a real directory, everything in it. Never follows symlinks. */
    fun deleteTree(f: File) {
        val st = try { Os.lstat(f.path) } catch (e: ErrnoException) { return }
        if (OsConstants.S_ISDIR(st.st_mode)) {
            try { Os.chmod(f.path, "700".toInt(8)) } catch (_: ErrnoException) {}
            f.list()?.forEach { deleteTree(File(f, it)) }
        }
        if (!f.delete()) Log.w("Cwaude", "couldn't delete $f")
    }
}
