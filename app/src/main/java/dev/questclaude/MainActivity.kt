package dev.questclaude

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings as SysSettings
import android.speech.RecognizerIntent
import android.view.View
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
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
    @Volatile private var adbListening = false

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val poll = object : Runnable {
        override fun run() { refreshStatus(); main.postDelayed(this, 3000) }
    }

    private val askTermuxPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { refreshStatus() }

    private val dictate =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { res ->
            val text = res.data
                ?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
                ?.firstOrNull() ?: return@registerForActivityResult
            insertAtCursor(text)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        settings = Settings(this)
        tmux = TmuxBridge(this, settings)

        compose = findViewById(R.id.compose)
        status = findViewById(R.id.status)
        lastResult = findViewById(R.id.last_result)

        findViewById<Button>(R.id.send).setOnClickListener { send() }
        findViewById<Button>(R.id.mic).setOnClickListener { startDictation() }
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
        ResultReceiver.listener = { label, ok, msg ->
            runOnUiThread {
                lastResult.text = if (ok) "✓ $label" else "✗ $label: $msg"
                lastResult.setTextColor(if (ok) GREEN else RED)
            }
        }
        main.post(poll)
    }

    override fun onPause() {
        super.onPause()
        ResultReceiver.listener = null
        main.removeCallbacks(poll)
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

    private fun startDictation() {
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PROMPT, "Speak to Claude")
        try {
            dictate.launch(intent)
        } catch (e: ActivityNotFoundException) {
            // Quest often has no standalone recognizer; the system keyboard's mic works.
            compose.requestFocus()
            getSystemService(InputMethodManager::class.java)
                .showSoftInput(compose, InputMethodManager.SHOW_IMPLICIT)
            toast("No speech app found — use the mic on the keyboard")
        }
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

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    companion object {
        private val GREEN = Color.parseColor("#7BD88F")
        private val AMBER = Color.parseColor("#F2C063")
        private val RED = Color.parseColor("#FF7A7A")
    }
}
