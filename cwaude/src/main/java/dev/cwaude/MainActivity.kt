package dev.cwaude

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings as SysSettings
import android.util.Log
import android.util.TypedValue
import android.view.KeyEvent
import android.view.MotionEvent
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
import dev.questclaude.WhisperNative
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors

class MainActivity : AppCompatActivity(), CwaudeService.Listener {

    private lateinit var settings: Settings
    private lateinit var status: TextView
    private lateinit var lastResult: TextView
    private lateinit var dictationStatus: TextView
    private lateinit var term: TerminalView
    private lateinit var input: InputQueue
    private lateinit var ansi: Ansi
    private lateinit var termScroll: ScrollView
    /** Scrollback mirrored above the screen (when Claude isn't fullscreen). */
    private lateinit var history: TextView
    private var histSession = ""
    /** Scrollback lines shown so far, counted from the oldest. */
    private var histCount = 0
    /** When the outstanding history request was sent; 0 if none. */
    private var histFetchAt = 0L
    private lateinit var mic: Button
    private lateinit var dictation: Dictation
    /** Downloading/loading the model or transcribing; Dictate is disabled meanwhile. */
    private var dictationBusy = false
    /** Whisper runs here so it never holds up anything else. */
    private val speech = Executors.newSingleThreadExecutor()
    private var sessions = emptyList<String>()
    private lateinit var tabs: LinearLayout
    private var started = false
    @Volatile private var adbListening = false
    private var connection = "starting"
    private var visible = false

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool()
    private val poll = object : Runnable {
        override fun run() { refreshStatus(); main.postDelayed(this, 3000) }
    }

    private val askMic =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) toggleDictation() else toast("Dictation needs microphone access")
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Ubuntu.ready(this)) {
            startActivity(Intent(this, SetupActivity::class.java))
            finish()
            return
        }
        setContentView(R.layout.activity_main)
        settings = Settings(this)

        status = findViewById(R.id.status)
        lastResult = findViewById(R.id.last_result)
        dictationStatus = findViewById(R.id.dictation_status)
        term = findViewById(R.id.term)
        termScroll = findViewById(R.id.term_scroll)
        history = findViewById(R.id.history)

        dictation = Dictation(this)
        // Load the speech model now, not on the first Dictate, or the first seconds of talking
        // stream nothing while it loads.
        if (dictation.hasModel) speech.execute { runCatching { dictation.load() } }
        mic = findViewById(R.id.mic)
        mic.setOnClickListener { toggleDictation() }
        input = InputQueue { ops ->
            // Typing while reading back through the scrollback jumps to the prompt, like a terminal.
            if (ops.any { !it.startsWith("S:") }) scrollToBottom()
            val c = control()
            if (c == null) { main.post { input.done() }; showResult("✗ not connected yet", RED) }
            else c.input(ops) { main.post { input.done() } }
        }
        ansi = Ansi(getColor(R.color.fg), getColor(R.color.term_bg))
        term.input = input
        term.onScroll = ::previewScroll
        findViewById<Button>(R.id.keyboard).setOnClickListener { term.showKeyboard() }
        tabs = findViewById(R.id.tabs)
        findViewById<Button>(R.id.new_tab).setOnClickListener { newSession() }
        renderTabs()
        findViewById<Button>(R.id.reconnect).setOnClickListener { reconnect() }
        findViewById<Button>(R.id.settings).setOnClickListener { showSettings() }
        status.setOnClickListener { fixSetup() }

        buildKeyBar(findViewById(R.id.keybar))
        term.requestFocus() // so a hardware keyboard types into Claude right away
    }

    override fun onResume() {
        super.onResume()
        visible = true
        WirelessDebugging.enable(this) // in case the boot receiver didn't run
        CwaudeService.listener = this
        CwaudeService.start(this)
        CwaudeService.instance?.let { status(it.lastStatus) }
        main.post(poll)
        autoStart()
    }

    override fun onPause() {
        super.onPause()
        visible = false
        if (CwaudeService.listener === this) CwaudeService.listener = null
        main.removeCallbacks(poll)
    }

    private fun control() = CwaudeService.instance?.control?.takeIf { it.alive }

    // ---- Service events (any thread) ------------------------------------------

    override fun status(s: String) = runOnUiThread { connection = s; refreshStatus() }

    override fun closed(why: String) = runOnUiThread {
        connection = "disconnected"
        refreshStatus()
        // The last tab closed, or tmux went away: bring back a session, as at first start.
        if (visible) main.postDelayed({ CwaudeService.instance?.ensureUp() }, 300)
    }

    override fun sessionChanged(session: String) = runOnUiThread {
        // Usually the switch we asked for; otherwise tmux moved us (the tab we were on closed).
        if (session.isNotEmpty() && session != settings.session) {
            settings.session = session
            lastPane = ""
            resetHistory()
            renderTabs()
        }
    }

    override fun tabs(tabs: List<ControlClient.Tab>) = runOnUiThread {
        val names = tabs.map { it.name }
        val info = tabs.associate { it.name to TabInfo.parse(it.title, it.approval) }
        if (names != sessions || info != tabInfo) { sessions = names; tabInfo = info; renderTabs() }
    }

    override fun frame(f: ControlClient.Frame) {
        // Styling is the slow part; keep it off the UI thread.
        val raw = f.lines.joinToString("\n").trimEnd()
        val styled = ansi.render(raw, f.cursor)
        runOnUiThread { showPane(f, raw, styled) }
    }

    // ---- Autostart + terminal mirror ----------------------------------------

    /** Wireless debugging, adb on 5555, tmux and the Claude session; each a no-op when done. */
    private fun autoStart() {
        io.execute {
            if (!isListening(5555)) main.post { if (!started) reconnect() }
            started = true
        }
    }

    private var lastPane = ""

    private fun showPane(f: ControlClient.Frame, raw: String, styled: CharSequence) {
        if (f.session != settings.session) return // a frame from before a tab switch
        term.remoteScroll = f.fullscreen
        syncHistory(f.fullscreen, f.historySize)
        if (f.keyAt != 0L) {
            val ms = SystemClock.elapsedRealtime() - f.keyAt
            Log.i("Cwaude", "latency: key→output ${f.keyToOutputMs} ms, key→screen $ms ms")
        }
        if (raw == lastPane) return
        if (input.scrolling) return // taken mid-scroll; the scroll's own frame follows
        lastPane = raw
        val atBottom = !termScroll.canScrollVertically(1)
        shownLines = raw.split('\n')
        term.text = TapTargets.mark(styled)
        if (atBottom) termScroll.post { termScroll.fullScroll(View.FOCUS_DOWN) }
    }

    // ---- Scrollback -----------------------------------------------------------
    // Claude (CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN, set for every session) writes the conversation
    // into tmux scrollback. We copy it above the screen once, in chunks, then only the new lines,
    // so scrolling back is the ScrollView's own: instant, with nothing to load.

    private fun syncHistory(fullscreen: Boolean, size: Int) {
        if (histSession != settings.session) resetHistory()
        if (fullscreen) { if (histCount > 0) resetHistory(); return }
        if (size < histCount) resetHistory() // /clear, or the session was replaced
        val waiting = histFetchAt != 0L && System.currentTimeMillis() - histFetchAt < 5000
        if (size > histCount && !waiting) fetchHistory()
    }

    private fun resetHistory() {
        histSession = settings.session
        histCount = 0
        histFetchAt = 0
        history.text = ""
        history.visibility = View.GONE
    }

    private fun fetchHistory() {
        val c = control() ?: return
        histFetchAt = System.currentTimeMillis()
        c.history(histSession, histCount) { h -> runOnUiThread { showHistory(h) } }
    }

    private fun showHistory(h: ControlClient.History) {
        histFetchAt = 0
        if (h.session != histSession || histSession != settings.session) return
        if (h.reset) { resetHistory(); return } // the next frame fetches it again
        if (h.from != histCount || h.lines.isEmpty()) return
        val atBottom = !termScroll.canScrollVertically(1)
        if (history.textSize != term.textSize) history.setTextSize(TypedValue.COMPLEX_UNIT_PX, term.textSize)
        if (histCount > 0) history.append("\n")
        history.append(ansi.render("\u001B[0m" + h.lines.joinToString("\n"), null))
        history.visibility = View.VISIBLE
        histCount += h.lines.size
        if (atBottom) scrollToBottom()
        if (histCount < h.size) fetchHistory()
    }

    private fun scrollToBottom() =
        termScroll.post { termScroll.scrollTo(0, termScroll.getChildAt(0).height) }

    /** Raw (ANSI) lines of the pane on screen, for [previewScroll]. */
    private var shownLines: List<String>? = null
    private val ansiEscape = Regex("\u001B\\[[0-9;?]*[A-Za-z]")

    private var skeletons = 0

    /**
     * A dim placeholder bar for a line that's still on its way from Claude, so a preview reads
     * as loading rather than empty. Lengths vary like text; each bar keeps its length as it moves.
     */
    private fun skeletonLine(): String {
        val i = skeletons++
        val width = 28 + (i * 37 + (i * i) % 23) % 60
        return "  \u001B[38;5;237m" + "░".repeat(width) + "\u001B[0m"
    }

    /**
     * Fullscreen Claude only: move the transcript right away, before the scroll reaches Claude
     * and comes back, by shifting the lines above the input box by [lines]. The real pane
     * replaces this as soon as it arrives.
     */
    private fun previewScroll(lines: Int) {
        val cur = shownLines ?: return
        val plain = cur.map { ansiEscape.replace(it, "") }
        // Claude's input box: the last rule directly above a ❯ line.
        val box = (plain.size - 2 downTo 0).firstOrNull {
            plain[it].startsWith("────") && plain[it + 1].startsWith("❯")
        } ?: return
        val top = if (plain.first().startsWith("❯")) 1 else 0
        // Already at the bottom: Claude won't scroll further down, so neither do we.
        if (lines < 0 && plain.subList(top, box).none { "Jump to bottom" in it }) return
        val region = cur.subList(top, box)
        if (region.isEmpty()) return
        val n = lines.coerceIn(-region.size, region.size)
        val shifted = if (n > 0) List(n) { skeletonLine() } + region.dropLast(n)
        else region.drop(-n) + List(-n) { skeletonLine() }
        val next = cur.subList(0, top) + shifted + cur.subList(box, cur.size)
        shownLines = next
        lastPane = "" // so the real pane is drawn even if it matches the last frame
        term.text = TapTargets.mark(ansi.render(next.joinToString("\n"), null))
    }

    // ---- Sessions (tabs) -------------------------------------------------------

    private fun renderTabs() {
        tabs.removeAllViews()
        val names = (sessions + settings.session).distinct() // active one shows even before it exists
        for (name in names) {
            val b = layoutInflater.inflate(R.layout.tab_button, tabs, false) as Button
            val active = name == settings.session
            b.text = tabLabel(name, tabInfo[name], active)
            b.backgroundTintList = android.content.res.ColorStateList.valueOf(
                getColor(if (active) R.color.accent else R.color.key))
            b.setOnClickListener { switchSession(name) }
            b.setOnLongClickListener { confirmClose(name); true }
            tabs.addView(b)
            // A ✕ right after the active tab, so closing doesn't depend on knowing about long-press.
            if (active) {
                val x = layoutInflater.inflate(R.layout.tab_button, tabs, false) as Button
                x.text = "✕"
                x.minWidth = 0
                x.minimumWidth = 0
                x.setPadding(dp(12), 0, dp(12), 0)
                x.contentDescription = "Close $name"
                x.backgroundTintList = b.backgroundTintList
                (b.layoutParams as LinearLayout.LayoutParams).marginEnd = dp(2)
                x.setOnClickListener { confirmClose(name) }
                tabs.addView(x)
            }
        }
    }

    /** What each tab's Claude is doing and about, from its pane title. */
    private var tabInfo = emptyMap<String, TabInfo>()

    data class TabInfo(val state: State?, val topic: String) {
        enum class State { WORKING, YOUR_TURN, APPROVE }

        companion object {
            /** Claude titles its pane "✳ topic" while waiting and swaps ✳ for a spinner while working. */
            fun parse(title: String, approval: Boolean): TabInfo {
                val sp = title.indexOf(' ')
                if (sp !in 1..2 || title[0].isLetterOrDigit()) return TabInfo(null, "") // not Claude
                val state = when {
                    approval -> State.APPROVE
                    title.substring(0, sp) == "✳" -> State.YOUR_TURN
                    else -> State.WORKING
                }
                return TabInfo(state, title.substring(sp + 1).trim())
            }
        }
    }

    /** "name · status" over a smaller topic line. */
    private fun tabLabel(name: String, info: TabInfo?, active: Boolean): CharSequence {
        val s = android.text.SpannableStringBuilder(name)
        val (label, color) = when (info?.state) {
            TabInfo.State.WORKING -> "◐ working" to AMBER
            TabInfo.State.YOUR_TURN -> "● your turn" to GREEN
            TabInfo.State.APPROVE -> "● approve?" to RED
            null -> null to 0
        }
        if (label != null) {
            s.append("  ")
            val start = s.length
            s.append(label)
            // The active tab is accent-colored, so its status stays white but bold.
            if (!active) s.setSpan(android.text.style.ForegroundColorSpan(color), start, s.length, 0)
            s.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), start, s.length, 0)
        }
        val topic = info?.topic.orEmpty()
        if (topic.isNotEmpty()) {
            s.append('\n')
            val start = s.length
            s.append(if (topic.length > 30) topic.take(29).trimEnd() + "…" else topic)
            s.setSpan(android.text.style.RelativeSizeSpan(0.8f), start, s.length, 0)
            s.setSpan(android.text.style.ForegroundColorSpan(
                if (active) Color.WHITE else getColor(R.color.muted)), start, s.length, 0)
        }
        return s
    }

    // ---- Microgestures --------------------------------------------------------

    /**
     * The current scroll gesture (a swipe or one push of a controller stick): it ends after a
     * 300 ms lull. Its horizontal and vertical totals decide whether it's a tab switch.
     */
    private var gestureLastAt = 0L
    private var gestureH = 0f
    private var gestureV = 0f
    private var gestureSwitched = false

    /**
     * A clearly sideways scroll switches to the previous/next tab, once per gesture; anything
     * else keeps scrolling the terminal. The gesture's sideways total must reach
     * [SWITCH_SCROLL] and be at least twice its vertical total.
     */
    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (event.actionMasked != MotionEvent.ACTION_SCROLL) return super.dispatchGenericMotionEvent(event)
        val h = event.getAxisValue(MotionEvent.AXIS_HSCROLL)
        val v = event.getAxisValue(MotionEvent.AXIS_VSCROLL)
        val now = event.eventTime
        if (now - gestureLastAt > 300) { gestureH = 0f; gestureV = 0f; gestureSwitched = false }
        gestureLastAt = now
        gestureH += h
        gestureV += v
        val sideways = Math.abs(gestureH) > 2 * Math.abs(gestureV)
        if (!gestureSwitched && sideways && Math.abs(gestureH) >= SWITCH_SCROLL) {
            gestureSwitched = true
            cycleTab(if (gestureH > 0) 1 else -1)
        }
        // A sideways gesture is ours; don't let its events scroll the terminal (or tab strip).
        if (gestureSwitched || (sideways && v == 0f)) return true
        return super.dispatchGenericMotionEvent(event)
    }

    private fun cycleTab(step: Int) {
        val names = (sessions + settings.session).distinct()
        if (names.size < 2) return
        val i = names.indexOf(settings.session)
        switchSession(names[Math.floorMod(i + step, names.size)])
    }

    private fun switchSession(name: String) {
        if (name == settings.session) { term.requestFocus(); return }
        settings.session = name
        lastPane = ""
        resetHistory()
        term.text = "Opening $name…"
        renderTabs()
        term.requestFocus()
        control()?.switchTo(name)
    }

    /** ＋: list the projects in ~, then [pickProject]. */
    private fun newSession() {
        io.execute {
            val projects = try {
                Ubuntu.capture(this, "for d in ~/*/; do [ -d \"\$d.git\" ] && basename \"\$d\"; done; exit 0").second
                    .lines().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith("proot") }.sorted()
            } catch (e: Exception) { emptyList() }
            main.post { pickProject(projects) }
        }
    }

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

    private fun openTab(project: String?, worktree: Boolean) {
        val c = control() ?: return showResult("✗ not connected yet", RED)
        // Tab (and worktree) named after the project: quest-claude, quest-claude-2, ...
        val base = (project ?: "claude").replace(Regex("[^A-Za-z0-9_-]"), "-")
        val taken = (sessions + settings.session).toSet()
        val name = (sequenceOf(base) + generateSequence(2) { it + 1 }.map { "$base-$it" })
            .first { it !in taken }
        val command = if (project == null) settings.launchCommand
            else Tmux.claudeIn(project, if (worktree) name else null)
        c.newSession(name, command)
        switchSession(name)
    }

    private fun confirmClose(name: String) {
        AlertDialog.Builder(this)
            .setTitle("Close $name?")
            .setMessage("This ends the tmux session and the Claude running in it.")
            .setPositiveButton("Close") { _, _ ->
                val c = control() ?: return@setPositiveButton
                sessions = sessions - name
                if (name == settings.session) {
                    // Move to another tab first; if none is left, start a fresh home tab.
                    val next = sessions.firstOrNull() ?: Settings.DEFAULT_SESSION
                    if (next !in sessions) c.newSession(next, settings.launchCommand)
                    switchSession(next)
                }
                c.killSession(name)
                renderTabs()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- Dictation -----------------------------------------------------------

    /**
     * Ctrl+Shift+D (or a keyboard's voice key) starts/stops dictation; Esc cancels a recording.
     * Caught here, before the terminal, so Ctrl+Shift+D never reaches Claude as Ctrl+D (exit).
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // Ctrl+Tab / Ctrl+Shift+Tab: next / previous tab, like a browser.
        if (event.keyCode == KeyEvent.KEYCODE_TAB && event.isCtrlPressed) {
            if (event.action == KeyEvent.ACTION_DOWN) cycleTab(if (event.isShiftPressed) -1 else 1)
            return true
        }
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
        val gen = try {
            dictation.start()
        } catch (e: Exception) {
            showDictation("✗ dictation: ${e.message}", RED); return
        }
        streamed = ""
        dictationSession = settings.session
        speech.execute { runCatching { dictation.load() } } // warm up while you talk
        speech.execute { streamPartial(gen) }
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
    private fun streamPartial(gen: Int) {
        if (!dictation.isLive(gen)) return
        val t0 = System.nanoTime()
        val text = runCatching { dictation.partial(gen) }.getOrNull()
        // A pass with no speech returns at once; without this it spun thousands of times a second.
        val ms = (System.nanoTime() - t0) / 1_000_000
        if (ms < 200) Thread.sleep(200 - ms)
        main.post { if (text != null && dictation.isLive(gen)) typeStreamed(text) }
        if (dictation.isLive(gen)) speech.execute { streamPartial(gen) }
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

    private fun showResult(text: String, color: Int) = runOnUiThread {
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
        val adbOn = SysSettings.Global.getInt(contentResolver, SysSettings.Global.ADB_ENABLED, 0) == 1
        io.execute {
            val port = isListening(5555)
            adbListening = port
            main.post {
                val up = connection == "up" && control() != null
                val checks = listOf(
                    up to "Ubuntu + tmux",
                    adbOn to "USB debugging",
                    WirelessDebugging.isOn(this) to "Wireless debugging",
                    port to "adb :5555",
                )
                checklist = checks.joinToString("\n") { (ok, name) -> "${dot(ok)} $name" } +
                    (if (WirelessDebugging.canEnable(this)) "" else "\n(Wireless debugging can't auto-enable)") +
                    "\n\nService: $connection"
                // tmux and the adb port are what matter; the full list is one tap away.
                val ready = up && port
                status.text = when {
                    ready -> "● Ready"
                    !up -> "○ $connection"
                    else -> "○ " + checks.filterNot { it.first }.joinToString(", ") { "no ${it.second}" }
                }
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
            control() == null -> CwaudeService.instance?.ensureUp()
            !adbListening -> reconnect()
            else -> AlertDialog.Builder(this)
                .setTitle("Setup checklist")
                .setMessage(checklist + "\n\n" + getString(R.string.setup_help))
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun reconnect() {
        if (!WirelessDebugging.enable(this)) {
            showResult(if (WirelessDebugging.canEnable(this))
                "✗ couldn't turn on Wireless debugging; turn it on in Settings > Developer, then Reconnect"
            else
                "✗ missing permission to turn on Wireless debugging; run scripts/install.sh --cwaude once " +
                    "(or turn it on in Settings > Developer), then Reconnect", RED)
            return
        }
        showResult("… reconnecting adb (scanning for the Wireless debugging port, ~15 s)", AMBER)
        val cmd = settings.reconnectCommand
        io.execute {
            val (code, out) = try {
                Ubuntu.capture(this, "bash -lc \"\$1\" 2>&1", cmd)
            } catch (e: Exception) { -1 to (e.message ?: "failed") }
            val last = out.lines().map { it.trim() }.lastOrNull { it.isNotEmpty() && !it.startsWith("proot") }.orEmpty()
            when {
                code == 0 -> showResult("✓ reconnect: $last", GREEN)
                code == 127 || "command not found" in out -> showResult(
                    "✗ '${cmd.substringBefore(' ')}' isn't installed in Cwaude's Ubuntu: clone quest-claude there " +
                        "and run scripts/setup.sh (or change the command in ⚙)", RED)
                else -> showResult("✗ reconnect (exit $code): $last", RED)
            }
            main.post { refreshStatus() }
        }
    }

    // ---- Settings ------------------------------------------------------------

    private fun showSettings() {
        val v = layoutInflater.inflate(R.layout.dialog_settings, null)
        val session = v.findViewById<EditText>(R.id.session).apply { setText(settings.session) }
        val launch = v.findViewById<EditText>(R.id.launch).apply { setText(settings.launchCommand) }
        val reconnect = v.findViewById<EditText>(R.id.reconnect_cmd).apply { setText(settings.reconnectCommand) }
        AlertDialog.Builder(this)
            .setTitle("Settings")
            .setView(v)
            .setPositiveButton("Save") { _, _ ->
                val old = settings.session
                settings.launchCommand = launch.text.toString()
                settings.reconnectCommand = reconnect.text.toString()
                val name = session.text.toString().trim().ifEmpty { Settings.DEFAULT_SESSION }
                if (name != old) {
                    if (name !in sessions) control()?.newSession(name, settings.launchCommand)
                    switchSession(name)
                }
            }
            .setNeutralButton("Reset") { _, _ ->
                settings.launchCommand = ""
                settings.reconnectCommand = ""
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- Helpers -------------------------------------------------------------

    override fun onDestroy() {
        super.onDestroy()
        if (::dictation.isInitialized) {
            speech.execute { dictation.close() }
        }
        speech.shutdown()
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    private fun toast(msg: String) = Toast.makeText(this, msg, Toast.LENGTH_LONG).show()

    companion object {
        /** Sideways scroll (in scroll units) one gesture needs before it switches tabs. */
        private const val SWITCH_SCROLL = 0.5f
        private val GREEN = Color.parseColor("#7BD88F")
        private val AMBER = Color.parseColor("#F2C063")
        private val RED = Color.parseColor("#FF7A7A")
    }
}
