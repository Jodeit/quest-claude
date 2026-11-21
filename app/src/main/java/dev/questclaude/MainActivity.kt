package dev.questclaude

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings as SysSettings
import android.view.View
import android.widget.Button
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
        term = findViewById(R.id.term)
        termScroll = findViewById(R.id.term_scroll)

        dictation = Dictation(this)
        mic = findViewById(R.id.mic)
        mic.setOnClickListener { toggleDictation() }
        input = InputQueue { ops -> guarded { tmux.input(ops) } }
        ansi = Ansi(getColor(R.color.fg), getColor(R.color.term_bg))
        term.input = input
        findViewById<Button>(R.id.keyboard).setOnClickListener { term.showKeyboard() }
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
                else if (label == "input") {
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

    /** Capture right after typing, instead of waiting for the next 1.2 s tick. */
    private fun refreshPaneSoon() {
        if (mirrorStopped) return
        main.removeCallbacks(mirror)
        capturePending = 0
        main.postDelayed(mirror, 80)
    }

    // ---- Dictation -----------------------------------------------------------

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
        showResult("… downloading the speech model (${Dictation.MODEL_MB} MB, once)", AMBER)
        speech.execute {
            try {
                dictation.downloadModel { pct ->
                    if (pct >= 0) main.post {
                        showResult("… downloading the speech model: $pct% of ${Dictation.MODEL_MB} MB", AMBER)
                    }
                }
                main.post { dictationBusy = false; mic.isEnabled = true; startRecording() }
            } catch (e: Exception) {
                main.post {
                    dictationBusy = false; mic.isEnabled = true
                    showResult("✗ dictation: ${e.message}", RED)
                }
            }
        }
    }

    private fun startRecording() {
        try {
            dictation.start()
        } catch (e: Exception) {
            showResult("✗ dictation: ${e.message}", RED); return
        }
        speech.execute { runCatching { dictation.load() } } // warm up while you talk
        mic.text = "■ Stop"
        showResult("● listening — tap Stop when you're done", RED)
    }

    private fun finishDictation() {
        dictationBusy = true
        mic.isEnabled = false
        mic.text = "… Transcribing"
        showResult("… transcribing", AMBER)
        speech.execute {
            val result = runCatching { dictation.stopAndTranscribe() }
            main.post {
                dictationBusy = false
                mic.isEnabled = true
                mic.text = getString(R.string.dictate)
                result.onSuccess { text ->
                    if (text.isEmpty()) showResult("✗ didn't catch anything", AMBER)
                    else {
                        // Pasted into Claude's prompt without Enter, so you can check it first.
                        input.paste(text)
                        term.requestFocus()
                        showResult("✓ dictated — press Enter to send", GREEN)
                    }
                }.onFailure { showResult("✗ dictation: ${it.message}", RED) }
            }
        }
    }

    private fun showResult(text: String, color: Int) {
        lastResult.text = text
        lastResult.setTextColor(color)
    }

    // ---- Key bar -------------------------------------------------------------

    private fun buildKeyBar(bar: LinearLayout) {
        val keys = listOf(
            "Esc" to arrayOf("Escape"),
            "Ctrl-C" to arrayOf("C-c"),
            "Tab" to arrayOf("Tab"),
            "⇧Tab" to arrayOf("BTab"),
            "←" to arrayOf("Left"),
            "↑" to arrayOf("Up"),
            "↓" to arrayOf("Down"),
            "→" to arrayOf("Right"),
            "⏎" to arrayOf("Enter"),
        )
        for ((label, k) in keys) {
            val b = layoutInflater.inflate(R.layout.key_button, bar, false) as Button
            b.text = label
            b.isFocusable = false // keep keyboard focus on the terminal
            b.setOnClickListener { k.forEach(input::key) }
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
                val parts = listOf(
                    dot(termux) + " Termux",
                    dot(perm) + " RUN_COMMAND",
                    dot(adbOn) + " USB debugging",
                    dot(WirelessDebugging.isOn(this)) + " Wireless debugging" +
                        (if (WirelessDebugging.canEnable(this)) "" else " (no auto-enable)"),
                    dot(port) + " adb :5555 " + (if (port) "listening" else "closed"),
                )
                status.text = parts.joinToString("    ")
                status.setTextColor(if (termux && perm && port) GREEN else AMBER)
            }
        }
    }

    private fun isListening(port: Int): Boolean = try {
        Socket().use { it.connect(InetSocketAddress("127.0.0.1", port), 300); true }
    } catch (e: Exception) { false }

    private fun dot(ok: Boolean) = if (ok) "●" else "○"

    private fun fixSetup() {
        when {
            !Termux.isInstalled(this) -> toast("Install Termux (F-Droid build) first")
            !Termux.hasPermission(this) -> askTermuxPermission.launch(Termux.PERMISSION)
            !adbListening -> reconnect()
            else -> AlertDialog.Builder(this)
                .setTitle("Setup checklist")
                .setMessage(getString(R.string.setup_help))
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
