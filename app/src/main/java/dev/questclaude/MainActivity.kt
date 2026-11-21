package dev.questclaude

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings as SysSettings
import android.view.KeyEvent
import android.view.View
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity() {

    private lateinit var settings: Settings
    private lateinit var tmux: TmuxBridge
    private lateinit var status: TextView
    private lateinit var lastResult: TextView
    private lateinit var dictationStatus: TextView
    private lateinit var term: TerminalView
    private lateinit var input: InputQueue
    private lateinit var ansi: Ansi
    private lateinit var termScroll: ScrollView
    private lateinit var mic: Button
    private lateinit var dictation: Dictation
    /** Downloading/loading the model or transcribing; Dictate is disabled meanwhile. */
    private var dictationBusy = false
    /** Whisper runs here so it never holds up the status checks on [io]. */
    private val speech = Executors.newSingleThreadExecutor()
    @Volatile private var capturePending = 0L
    private var lastPane = ""
    private var sessions = emptyList<String>()
    private lateinit var tabs: LinearLayout
    private var started = false
    /** Set when Termux rejects a command, so we don't post an error notification every second. */
    @Volatile private var mirrorStopped = false
    @Volatile private var adbListening = false

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val poll = object : Runnable {
        override fun run() { refreshStatus(); main.postDelayed(this, 3000) }
    }
    private val mirror = object : Runnable {
        override fun run() {
            // Don't pile up captures if Termux is slow to answer.
            val now = System.currentTimeMillis()
            if (mirrorStopped) return
            if (Termux.isInstalled(this@MainActivity) && Termux.hasPermission(this@MainActivity) &&
                now - capturePending > 5000
            ) {
                capturePending = now
                try { tmux.capture() } catch (_: Exception) { capturePending = 0 }
            }
            main.postDelayed(this, 1200)
        }
    }

    private val askTermuxPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshStatus() }

    private val askMic =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) toggleDictation() else toast("Dictation needs microphone access")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        settings = Settings(this)
        tmux = TmuxBridge(this, settings)

        status = findViewById(R.id.status)
        lastResult = findViewById(R.id.last_result)
        dictationStatus = findViewById(R.id.dictation_status)
        term = findViewById(R.id.term)
        termScroll = findViewById(R.id.term_scroll)

        dictation = Dictation(this)
        mic = findViewById(R.id.mic)
        mic.setOnClickListener { toggleDictation() }
        input = InputQueue { ops -> guarded { tmux.input(ops) } }
        ansi = Ansi(getColor(R.color.fg), getColor(R.color.term_bg))
        term.input = input
        findViewById<Button>(R.id.keyboard).setOnClickListener { term.showKeyboard() }
        tabs = findViewById(R.id.tabs)
        findViewById<Button>(R.id.new_tab).setOnClickListener { newSession() }
        renderTabs()
        findViewById<Button>(R.id.open_session).setOnClickListener { guarded { tmux.openSession() } }
        findViewById<Button>(R.id.reconnect).setOnClickListener { reconnect() }
        findViewById<Button>(R.id.remote).setOnClickListener { guarded { tmux.openRemote() } }
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }
        status.setOnClickListener { fixSetup() }

        buildKeyBar(findViewById(R.id.keybar))
        term.requestFocus() // so a hardware keyboard types into Claude right away
    }

    override fun onResume() {
        super.onResume()
        WirelessDebugging.enable(this) // in case the boot receiver didn't run
        ResultReceiver.listener = { label, ok, msg, stdout ->
            runOnUiThread {
                if (label == "mirror") showPane(ok, stdout, msg)
                else if (label == "projects" && pickingProject) {
                    pickingProject = false
                    pickProject(stdout.lines().map { it.trim() }.filter { it.isNotEmpty() }.sorted())
                } else if (label == "input") {
                    input.done()
                    if (stdout.isNotBlank()) showResult("✗ typing: ${stdout.trim()}", RED)
                    refreshPaneSoon()
                } else {
                    lastResult.text = if (ok) "✓ $label" else "✗ $label: $msg"
                    lastResult.setTextColor(if (ok) GREEN else RED)
                    if (msg.contains("allow-external-apps")) {
                        mirrorStopped = true
                        main.removeCallbacks(mirror)
                        term.text = getString(R.string.setup_help)
                    }
                }
            }
        }
        main.post(poll)
        mirrorStopped = false
        main.post(mirror)
        autoStart()
    }

    override fun onPause() {
        super.onPause()
        ResultReceiver.listener = null
        main.removeCallbacks(poll)
        main.removeCallbacks(mirror)
    }

    // ---- Autostart + terminal mirror ----------------------------------------

    /**
     * Everything that used to need Termux by hand: Wireless debugging, adb on 5555, tmux, and
     * the Claude session. Runs on every resume; each step is a no-op when already done.
     */
    private fun autoStart() {
        if (!Termux.isInstalled(this) || !Termux.hasPermission(this)) { fixSetup(); return }
        tmux.ensureSession()
        io.execute {
            if (!isListening(5555)) main.post {
                if (!started) reconnect()
            }
            started = true
        }
    }

    private fun showPane(ok: Boolean, text: String, msg: String) {
        capturePending = 0
        if (!ok) {
            // Termux refused the command itself (e.g. allow-external-apps is off). Retrying every
            // second would only pile up notifications, so stop until the app is reopened.
            mirrorStopped = true
            main.removeCallbacks(mirror)
            lastPane = ""
            term.text = if (msg.contains("allow-external-apps")) getString(R.string.setup_help)
            else "Termux refused the command: $msg\n\nReopen the app to retry."
            return
        }
        // Line 1 is the session list for the tab strip; the rest is the active pane.
        val nl0 = text.indexOf('\n')
        val names = (if (nl0 >= 0) text.substring(0, nl0) else "").split('\t').filter { it.isNotBlank() }
        if (names != sessions) { sessions = names; renderTabs() }
        val text = if (nl0 >= 0) text.substring(nl0 + 1) else text
        if (text.contains(TmuxBridge.NO_SESSION)) {
            lastPane = ""
            term.text = "Claude isn't running yet. The first start installs tmux in Termux, which " +
                "takes about a minute. If it doesn't come up, reopen the app or tap Open Claude."
            return
        }
        if (text == lastPane) return
        lastPane = text
        // First line is "cursor_x cursor_y cursor_flag"; Claude hides the real cursor and draws its own.
        val nl = text.indexOf('\n')
        val head = if (nl >= 0) text.substring(0, nl).split(' ') else emptyList()
        val pane = if (nl >= 0) text.substring(nl + 1) else text
        val cursor = if (head.getOrNull(2) == "1")
            head[0].toIntOrNull()?.let { x -> head[1].toIntOrNull()?.let { y -> x to y } } else null
        val atBottom = !termScroll.canScrollVertically(1)
        term.text = ansi.render(pane.trimEnd(), cursor)
        if (atBottom) termScroll.post { termScroll.fullScroll(View.FOCUS_DOWN) }
    }

    // ---- Sessions (tabs) -------------------------------------------------------

    private fun renderTabs() {
        tabs.removeAllViews()
        val names = (sessions + settings.session).distinct() // active one shows even before it exists
        for (name in names) {
            val b = layoutInflater.inflate(R.layout.tab_button, tabs, false) as Button
            b.text = name
            val active = name == settings.session
            b.backgroundTintList = android.content.res.ColorStateList.valueOf(
                getColor(if (active) R.color.accent else R.color.key))
            b.setOnClickListener { switchSession(name) }
            b.setOnLongClickListener { confirmClose(name); true }
            tabs.addView(b)
        }
    }

    private fun switchSession(name: String) {
        if (name == settings.session) { term.requestFocus(); return }
        settings.session = name
        lastPane = ""
        term.text = "Opening $name…"
        renderTabs()
        term.requestFocus()
        refreshPaneSoon()
    }

    /** A new tab running another Claude (the launch command), named claude-2, claude-3, ... */
    /** ＋: ask Termux for the projects in ~, then [pickProject] when the list arrives. */
    private fun newSession() = guarded {
        pickingProject = true
        tmux.listProjects()
    }

    private var pickingProject = false

    /**
     * Where the new tab's Claude runs. For a git repo it gets its own worktree by default
     * (`claude -w`), so several tabs can work on the same repo without editing the same files.
     */
    private fun pickProject(projects: List<String>) {
        val items = listOf("~ (home)") + projects
        var choice = items.indexOf(settings.lastProject).takeIf { it > 0 } ?: 0
        val isolate = CheckBox(this).apply {
            text = "Own git worktree, so it can't collide with other tabs on this repo"
            setTextColor(getColor(R.color.fg))
            isChecked = settings.isolateTabs
            isEnabled = choice > 0
            setPadding(24, 16, 24, 16)
        }
        AlertDialog.Builder(this)
            .setTitle("New Claude tab")
            .setSingleChoiceItems(items.toTypedArray(), choice) { _, which ->
                choice = which
                isolate.isEnabled = which > 0
            }
            .setView(isolate)
            .setPositiveButton("Open") { _, _ ->
                val project = if (choice == 0) null else items[choice]
                val worktree = project != null && isolate.isChecked
                settings.lastProject = items[choice]
                if (project != null) settings.isolateTabs = isolate.isChecked
                openTab(project, worktree)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun openTab(project: String?, worktree: Boolean) = guarded {
        // Tab (and worktree) named after the project: quest-claude, quest-claude-2, ...
        val base = (project ?: "claude").replace(Regex("[^A-Za-z0-9_-]"), "-")
        val taken = (sessions + settings.session).toSet()
        val name = (sequenceOf(base) + generateSequence(2) { it + 1 }.map { "$base-$it" })
            .first { it !in taken }
        val command = if (project == null) settings.launchCommand
            else TmuxBridge.claudeIn(project, if (worktree) name else null)
        tmux.startSession(name, command)
        switchSession(name)
    }

    private fun confirmClose(name: String) {
        AlertDialog.Builder(this)
            .setTitle("Close $name?")
            .setMessage("This ends the tmux session and the Claude running in it.")
            .setPositiveButton("Close") { _, _ ->
                guarded {
                    tmux.killSession(name)
                    sessions = sessions - name
                    if (name == settings.session) {
                        // Move to another tab; if none is left, autostart brings back a fresh one.
                        val next = sessions.firstOrNull() ?: Settings.DEFAULT_SESSION
                        if (next == Settings.DEFAULT_SESSION && next !in sessions) tmux.startSession(next)
                        switchSession(next)
                    } else renderTabs()
                }
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** Capture right after typing, instead of waiting for the next 1.2 s tick. */
    private fun refreshPaneSoon() {
        if (mirrorStopped) return
        main.removeCallbacks(mirror)
        capturePending = 0
        main.postDelayed(mirror, 80)
    }

    // ---- Dictation -----------------------------------------------------------

    /**
     * Ctrl+Shift+D (or a keyboard's voice key) starts/stops dictation; Esc cancels a recording.
     * Caught here, before the terminal, so Ctrl+Shift+D never reaches Claude as Ctrl+D (exit).
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val dictateKey = (event.keyCode == KeyEvent.KEYCODE_D && event.isCtrlPressed && event.isShiftPressed) ||
            event.keyCode == KeyEvent.KEYCODE_VOICE_ASSIST
        val cancelKey = event.keyCode == KeyEvent.KEYCODE_ESCAPE && dictation.recording && !dictationBusy
        if (!dictateKey && !cancelKey) return super.dispatchKeyEvent(event)
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            if (cancelKey) cancelDictation() else toggleDictation()
        }
        return true
    }

    private fun cancelDictation() {
        dictation.cancel() // waits at most one 100 ms mic read
        typeStreamed("") // take back what was typed live
        streamed = ""
        mic.text = getString(R.string.dictate)
        showDictation("dictation cancelled", AMBER, hideAfterMs = 3000)
    }

    private fun toggleDictation() {
        if (dictationBusy) return
        if (dictation.recording) { finishDictation(); return }
        if (!WhisperNative.loaded) {
            // Shouldn't happen with a CI build, but the keyboard's own mic still works.
            term.showKeyboard()
            toast("Whisper isn't available in this build — use the mic on the keyboard")
            return
        }
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            askMic.launch(Manifest.permission.RECORD_AUDIO); return
        }
        if (dictation.hasModel) { startRecording(); return }
        dictationBusy = true
        mic.isEnabled = false
        showDictation("… downloading the speech model (${Dictation.MODEL_MB} MB, once)", AMBER)
        speech.execute {
            try {
                dictation.downloadModel { pct ->
                    if (pct >= 0) main.post {
                        showDictation("… downloading the speech model: $pct% of ${Dictation.MODEL_MB} MB", AMBER)
                    }
                }
                main.post { dictationBusy = false; mic.isEnabled = true; startRecording() }
            } catch (e: Exception) {
                main.post {
                    dictationBusy = false; mic.isEnabled = true
                    showDictation("✗ dictation: ${e.message}", RED)
                }
            }
        }
    }

    private fun startRecording() {
        try {
            dictation.start()
        } catch (e: Exception) {
            showDictation("✗ dictation: ${e.message}", RED); return
        }
        streamed = ""
        dictationSession = settings.session
        speech.execute { runCatching { dictation.load() } } // warm up while you talk
        speech.execute(::streamPartial)
        mic.text = "■ Stop"
        showDictation("● listening — Stop or Ctrl+Shift+D to finish, Esc to cancel", RED)
    }

    /** Text dictation has typed into the prompt so far, so updates can be sent as edits. */
    private var streamed = ""
    /** The tab dictation started in; streaming stops typing if you switch away. */
    private var dictationSession = ""

    /**
     * Runs on [speech] over and over while recording: transcribe what's been said so far and
     * type it into Claude's prompt as you talk, fixing earlier words as Whisper revises them.
     */
    private fun streamPartial() {
        if (!dictation.recording) return
        val text = runCatching { dictation.partial() }.getOrNull()
        main.post { if (text != null && dictation.recording) typeStreamed(text) }
        if (dictation.recording) speech.execute(::streamPartial)
    }

    /** Make the prompt show [text]: backspace over what changed, type the new tail. */
    private fun typeStreamed(text: String) {
        if (settings.session != dictationSession) return
        val keep = streamed.commonPrefixWith(text).length
        input.keys("BSpace", streamed.length - keep)
        if (text.length > keep) input.literal(text.substring(keep))
        streamed = text
    }

    private fun finishDictation() {
        dictationBusy = true
        mic.isEnabled = false
        mic.text = "… Finishing"
        showDictation("… finishing the last words", AMBER)
        speech.execute {
            val result = runCatching { dictation.stopAndTranscribe() }
            main.post {
                dictationBusy = false
                mic.isEnabled = true
                mic.text = getString(R.string.dictate)
                result.onSuccess { text ->
                    // Picks up the last words and any late corrections, in place. No Enter, so
                    // you can check it first.
                    typeStreamed(text)
                    streamed = ""
                    term.requestFocus()
                    if (text.isEmpty()) showDictation("✗ didn't catch anything", AMBER, hideAfterMs = 4000)
                    else showDictation("✓ dictated — press Enter to send", GREEN, hideAfterMs = 4000)
                }.onFailure { streamed = ""; showDictation("✗ dictation: ${it.message}", RED) }
            }
        }
    }

    private fun showResult(text: String, color: Int) {
        lastResult.text = text
        lastResult.setTextColor(color)
    }

    private val hideDictation = Runnable { dictationStatus.visibility = View.GONE }

    /** Dictation progress goes on the line above the mic button, not in the header. */
    private fun showDictation(text: String, color: Int, hideAfterMs: Long = 0) {
        main.removeCallbacks(hideDictation)
        dictationStatus.text = text
        dictationStatus.setTextColor(color)
        dictationStatus.visibility = View.VISIBLE
        if (hideAfterMs > 0) main.postDelayed(hideDictation, hideAfterMs)
    }

    // ---- Key bar -------------------------------------------------------------

    private fun buildKeyBar(bar: LinearLayout) {
        fun send(vararg names: String): () -> Unit = { names.forEach(input::key) }
        val keys = listOf(
            "Esc" to send("Escape"),
            "Ctrl-C" to send("C-c"),
            // Esc and Ctrl-C interrupt Claude while it's working; Clear only empties the prompt.
            "Clear" to input::clearPrompt,
            "Tab" to send("Tab"),
            "⇧Tab" to send("BTab"),
            "←" to send("Left"),
            "↑" to send("Up"),
            "↓" to send("Down"),
            "→" to send("Right"),
            "⏎" to send("Enter"),
        )
        for ((label, action) in keys) {
            val b = layoutInflater.inflate(R.layout.key_button, bar, false) as Button
            b.text = label
            b.isFocusable = false // keep keyboard focus on the terminal
            b.setOnClickListener { action() }
            bar.addView(b)
        }
    }

    // ---- Status --------------------------------------------------------------

    private fun refreshStatus() {
        val termux = Termux.isInstalled(this)
        val perm = Termux.hasPermission(this)
        val adbOn = SysSettings.Global.getInt(contentResolver, SysSettings.Global.ADB_ENABLED, 0) == 1
        io.execute {
            val port = isListening(5555)
            adbListening = port
            main.post {
                val checks = listOf(
                    termux to "Termux",
                    perm to "RUN_COMMAND",
                    adbOn to "USB debugging",
                    WirelessDebugging.isOn(this) to "Wireless debugging",
                    port to "adb :5555",
                )
                checklist = checks.joinToString("\n") { (ok, name) -> "${dot(ok)} $name" } +
                    (if (WirelessDebugging.canEnable(this)) "" else "\n(Wireless debugging can't auto-enable)")
                // Termux, RUN_COMMAND and the adb port are what matter; the full list is one tap away.
                val ready = termux && perm && port
                status.text = if (ready) "● Ready"
                else "○ " + checks.filterNot { it.first }.joinToString(", ") { "no ${it.second}" }
                status.setTextColor(if (ready) GREEN else AMBER)
            }
        }
    }

    private fun isListening(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300); true }
    } catch (e: Exception) { false }

    private fun dot(ok: Boolean) = if (ok) "●" else "○"

    /** Every setup check with its dot, for the dialog behind the status pill. */
    private var checklist = ""

    private fun fixSetup() {
        when {
            !Termux.isInstalled(this) -> toast("Install Termux (F-Droid build) first")
            !Termux.hasPermission(this) -> askTermuxPermission.launch(Termux.PERMISSION)
            !adbListening -> reconnect()
            else -> AlertDialog.Builder(this)
                .setTitle("Setup checklist")
                .setMessage(checklist + "\n\n" + getString(R.string.setup_help))
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun reconnect() = guarded {
        if (!WirelessDebugging.enable(this)) {
            lastResult.text = if (WirelessDebugging.canEnable(this))
                "✗ couldn't turn on Wireless debugging; turn it on in Settings > Developer, then Reconnect"
            else
                "✗ missing permission to turn on Wireless debugging; run scripts/install.sh once " +
                    "(or turn it on in Settings > Developer), then Reconnect"
            lastResult.setTextColor(RED)
            return@guarded
        }
        lastResult.text = "… reconnecting adb (scanning for the Wireless debugging port, ~15 s)"
        lastResult.setTextColor(AMBER)
        tmux.reconnect()
    }

    // ---- Settings ------------------------------------------------------------

    private fun showSettings() {
        val v = layoutInflater.inflate(R.layout.dialog_settings, null)
        val session = v.findViewById<EditText>(R.id.session).apply { setText(settings.session) }
        val launch = v.findViewById<EditText>(R.id.launch).apply { setText(settings.launchCommand) }
        val reconnect = v.findViewById<EditText>(R.id.reconnect_cmd).apply { setText(settings.reconnectCommand) }
        val remote = v.findViewById<EditText>(R.id.remote_cmd).apply { setText(settings.remoteCommand) }
        AlertDialog.Builder(this)
            .setTitle("Settings")
            .setView(v)
            .setPositiveButton("Save") { _, _ ->
                settings.session = session.text.toString()
                settings.launchCommand = launch.text.toString()
                settings.reconnectCommand = reconnect.text.toString()
                settings.remoteCommand = remote.text.toString()
            }
            .setNeutralButton("Reset") { _, _ ->
                settings.session = ""
                settings.launchCommand = ""
                settings.reconnectCommand = ""
                settings.remoteCommand = ""
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- Helpers -------------------------------------------------------------

    /** Runs [block] only if Termux is ready; otherwise walks the user through setup. */
    private fun guarded(block: () -> Unit) {
        if (!Termux.isInstalled(this) || !Termux.hasPermission(this)) {
            fixSetup(); return
        }
        try {
            block()
        } catch (e: Exception) {
            lastResult.text = "✗ ${e.javaClass.simpleName}: ${e.message}"
            lastResult.setTextColor(RED)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        speech.execute { dictation.close() }
        speech.shutdown()
    }

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    companion object {
        private val GREEN = Color.parseColor("#7BD88F")
        private val AMBER = Color.parseColor("#F2C063")
        private val RED = Color.parseColor("#FF7A7A")
    }
}
