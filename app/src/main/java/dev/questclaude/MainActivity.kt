package dev.questclaude

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings as SysSettings
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.InputMethodManager
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
    private lateinit var compose: EditText
    private lateinit var status: TextView
    private lateinit var lastResult: TextView
    private lateinit var term: TextView
    private lateinit var termScroll: ScrollView
    private lateinit var mic: Button
    private lateinit var dictation: Dictation
    /** Downloading/loading the model or transcribing; Dictate is disabled meanwhile. */
    private var dictationBusy = false
    /** Whisper runs here so it never holds up the status checks on [io]. */
    private val speech = Executors.newSingleThreadExecutor()
    @Volatile private var capturePending = 0L
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

        compose = findViewById(R.id.compose)
        status = findViewById(R.id.status)
        lastResult = findViewById(R.id.last_result)
        term = findViewById(R.id.term)
        termScroll = findViewById(R.id.term_scroll)

        findViewById<Button>(R.id.send).setOnClickListener { send() }
        dictation = Dictation(this)
        mic = findViewById(R.id.mic)
        mic.setOnClickListener { toggleDictation() }
        // Enter on a hardware keyboard sends; Shift+Enter adds a line. The on-screen keyboard
        // (a virtual device) still inserts newlines.
        compose.setOnKeyListener { _, code, ev ->
            val enter = code == KeyEvent.KEYCODE_ENTER || code == KeyEvent.KEYCODE_NUMPAD_ENTER
            val hardware = ev.deviceId != KeyCharacterMap.VIRTUAL_KEYBOARD && ev.device?.isVirtual == false
            if (!enter || !hardware || ev.isShiftPressed) return@setOnKeyListener false
            if (ev.action == KeyEvent.ACTION_DOWN && ev.repeatCount == 0) send()
            true
        }
        findViewById<Button>(R.id.clear).setOnClickListener { compose.text.clear() }
        findViewById<Button>(R.id.open_session).setOnClickListener { guarded { tmux.openSession() } }
        findViewById<Button>(R.id.reconnect).setOnClickListener { reconnect() }
        findViewById<Button>(R.id.remote).setOnClickListener { guarded { tmux.openRemote() } }
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }
        status.setOnClickListener { fixSetup() }

        val submit = findViewById<CheckBox>(R.id.submit)
        submit.isChecked = settings.submitOnSend
        submit.setOnCheckedChangeListener { _, v -> settings.submitOnSend = v }

        buildKeyBar(findViewById(R.id.keybar))
    }

    override fun onResume() {
        super.onResume()
        WirelessDebugging.enable(this) // in case the boot receiver didn't run
        ResultReceiver.listener = { label, ok, msg, stdout ->
            runOnUiThread {
                if (label == "mirror") showPane(ok, stdout, msg)
                else {
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
            term.text = if (msg.contains("allow-external-apps")) getString(R.string.setup_help)
            else "Termux refused the command: $msg\n\nReopen the app to retry."
            return
        }
        if (text.contains(TmuxBridge.NO_SESSION)) {
            term.text = "Claude isn't running yet. The first start installs tmux in Termux, which " +
                "takes about a minute. If it doesn't come up, reopen the app or tap Open Claude."
            return
        }
        val atBottom = !termScroll.canScrollVertically(1)
        val trimmed = text.trimEnd()
        if (term.text.toString() != trimmed) {
            term.text = trimmed
            if (atBottom) termScroll.post { termScroll.fullScroll(View.FOCUS_DOWN) }
        }
    }

    // ---- Compose / send ------------------------------------------------------

    private fun send() {
        val text = compose.text.toString()
        if (text.isBlank()) {
            guarded { tmux.sendKeys("Enter") }
            return
        }
        guarded {
            tmux.sendText(text, settings.submitOnSend)
            compose.text.clear()
        }
    }

    private fun insertAtCursor(text: String) {
        val start = compose.selectionStart.coerceAtLeast(0)
        val needsSpace = start > 0 && !compose.text[start - 1].isWhitespace()
        compose.text.insert(start, if (needsSpace) " $text" else text)
    }

    private fun toggleDictation() {
        if (dictationBusy) return
        if (dictation.recording) { finishDictation(); return }
        if (!WhisperNative.loaded) {
            // Shouldn't happen with a CI build, but the keyboard's own mic still works.
            compose.requestFocus()
            getSystemService(InputMethodManager::class.java)
                .showSoftInput(compose, InputMethodManager.SHOW_IMPLICIT)
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
                    else { insertAtCursor(text); showResult("✓ dictated", GREEN) }
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
            b.setOnClickListener { guarded { tmux.sendKeys(*k) } }
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
