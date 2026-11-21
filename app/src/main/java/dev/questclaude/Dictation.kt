package dev.questclaude

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/** whisper.cpp, built from app/src/main/cpp. */
object WhisperNative {
    val loaded: Boolean = try {
        System.loadLibrary("qcwhisper"); true
    } catch (e: Throwable) { false }

    external fun init(modelPath: String): Long
    /** [audioCtx] 0 = full 30 s encoder window; smaller is faster, for live partials. */
    external fun transcribe(ctx: Long, samples: FloatArray, threads: Int, audioCtx: Int): ByteArray?
    external fun free(ctx: Long)
}

/**
 * On-device dictation: records 16 kHz mono from the mic, then transcribes it with Whisper.
 * Quest has no speech recognizer that other apps can use, so this replaces RECOGNIZE_SPEECH.
 *
 * [downloadModel], [load] and [stopAndTranscribe] block; call them off the main thread.
 */
class Dictation(ctx: Context) {
    companion object {
        const val MODEL_NAME = "ggml-base.en-q5_1.bin"
        const val MODEL_MB = 57
        private const val MODEL_URL =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
        private const val RATE = 16000
        private const val MAX_SECONDS = 180
        private const val THREADS = 4
        /** Audio past this is transcribed for good and dropped from the live window. */
        private const val WINDOW_SECONDS = 8
        /** The commit cut goes at the quietest spot this far back from the window's end. */
        private const val CUT_SEARCH_SECONDS = 3
        /** Whisper's markers for non-speech, e.g. [BLANK_AUDIO], (wind blowing). */
        private val NON_SPEECH = Regex("""\[[^\]]*]|\([^)]*\)""")
        /** What's left of a marker Whisper didn't finish, e.g. "[" or "(sigh". */
        private val MARKER_SCRAPS = Regex("""\[[^\]]*$|\([^)]*$|[\[\]()]""")
        /** 50 ms frames quieter than this RMS are never speech. */
        private const val MIN_VOICE_RMS = 0.003
        /** Silence kept around the speech in a pass, so word edges aren't clipped. */
        private const val PAD_MS = 300
        /** A phrase of up to 6 words said 3+ times in a row: Whisper stuck in a loop. */
        private val LOOP = Regex("""(?<!\S)((?:\S+\s+){1,6}?)\1{2,}""", RegexOption.IGNORE_CASE)
    }

    private val modelFile = File(ctx.filesDir, MODEL_NAME)
    @Volatile private var handle = 0L
    @Volatile var recording = false
        private set
    private var recorder: Thread? = null
    private var audio = FloatArray(RATE * 30)
    private var size = 0
    /** Start of the live window; audio before it is already in [committed]. */
    private var windowStart = 0
    private var committed = ""
    /**
     * Bumped by every start and cancel. A transcription pass that began under an older value is
     * thrown away, so a quick stop-and-restart can't mix the last dictation into this one.
     */
    @Volatile var generation = 0
        private set

    val hasModel get() = modelFile.length() > 0

    fun downloadModel(progress: (Int) -> Unit) {
        val part = File(modelFile.path + ".part")
        val conn = URL(MODEL_URL).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 15000
        conn.readTimeout = 30000
        try {
            if (conn.responseCode != 200) error("model download failed: HTTP ${conn.responseCode}")
            val total = conn.contentLengthLong
            var done = 0L
            var lastPct = -1
            conn.inputStream.use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        done += n
                        val pct = if (total > 0) (done * 100 / total).toInt() else -1
                        if (pct != lastPct) { lastPct = pct; progress(pct) }
                    }
                }
            }
            if (total > 0 && done != total) error("model download was cut short; try again")
            if (!part.renameTo(modelFile)) error("couldn't save the model")
        } finally {
            conn.disconnect()
            part.delete()
        }
    }

    fun load() {
        if (handle != 0L) return
        if (!WhisperNative.loaded) error("Whisper isn't built into this APK")
        handle = WhisperNative.init(modelFile.path)
        if (handle == 0L) {
            modelFile.delete() // most likely corrupt; it downloads again next time
            error("couldn't load the speech model; tap Dictate to download it again")
        }
    }

    @SuppressLint("MissingPermission") // the caller checks RECORD_AUDIO
    fun start(): Int {
        if (recording) return generation
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT,
            maxOf(min, RATE * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release(); error("couldn't open the microphone")
        }
        synchronized(this) { size = 0; windowStart = 0; committed = ""; generation++ }
        recording = true
        recorder = Thread {
            val chunk = FloatArray(RATE / 10)
            rec.startRecording()
            try {
                while (recording && size < RATE * MAX_SECONDS) {
                    val n = rec.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                    if (n <= 0) continue
                    synchronized(this) {
                        if (size + n > audio.size) audio = audio.copyOf(audio.size * 2)
                        System.arraycopy(chunk, 0, audio, size, n)
                        size += n
                    }
                }
            } finally {
                rec.stop(); rec.release()
            }
        }.apply { name = "dictation-mic"; start() }
        return generation
    }

    /** Still recording the dictation that [start] numbered [gen]. */
    fun isLive(gen: Int) = recording && generation == gen

    private fun run(samples: FloatArray, audioCtx: Int): String {
        load()
        val bytes = WhisperNative.transcribe(handle, samples, THREADS, audioCtx) ?: error("transcription failed")
        return clean(String(bytes, Charsets.UTF_8))
    }

    private fun clean(s: String): String {
        val words = s.replace(NON_SPEECH, "").replace(MARKER_SCRAPS, "").replace(Regex("\\s+"), " ").trim()
        if (words.none { it.isLetterOrDigit() }) return "" // just punctuation, e.g. "..."
        return collapseRepeats("$words ".replace(LOOP, "$1").trim())
    }

    /**
     * Whisper on a short phrase often loops it to the end of the pass: "Fix the tabs. Fix the
     * tabs. Fix the". Finds the earliest phrase of 3+ words that repeats back-to-back through to
     * the end (the last copy may stop mid-word) and keeps one copy.
     */
    private fun collapseRepeats(s: String): String {
        val w = s.split(" ")
        val n = w.map { word -> word.lowercase().filter { it.isLetterOrDigit() } }
        for (i in w.indices) {
            for (p in 3..(w.size - i) / 2) {
                val loops = (i + p until w.size).all { j ->
                    n[j] == n[j - p] || (j == w.size - 1 && n[j].isNotEmpty() && n[j - p].startsWith(n[j]))
                }
                if (loops) return w.subList(0, i + p).joinToString(" ")
            }
        }
        return s
    }

    /**
     * [a] then [b], dropping words at the start of [b] that repeat the end of [a]: a word right
     * at a commit cut can be heard in both windows.
     */
    private fun join(a: String, b: String): String {
        if (a.isEmpty() || b.isEmpty()) return a + b
        fun norm(w: String) = w.lowercase().filter { it.isLetterOrDigit() }
        val aw = a.split(" ").map(::norm)
        val bw = b.split(" ")
        val overlap = (minOf(4, aw.size, bw.size) downTo 1).firstOrNull { k ->
            aw.takeLast(k) == bw.take(k).map(::norm)
        } ?: 0
        val rest = bw.drop(overlap).joinToString(" ")
        return if (rest.isEmpty()) a else "$a $rest"
    }

    /**
     * Encoder window sized to the audio: 50 frames per second plus margin, rounded up to 64, and
     * never under 256 (about 5 s). Whisper gets unreliable on a very short window, which made short
     * phrases hard to catch; 256 still costs only a fraction of a second.
     */
    private fun audioCtx(samples: Int) =
        ((samples * 50 / RATE + 64 + 63) / 64 * 64).coerceIn(256, 1500)

    /** Index of the quietest 50 ms in the last [CUT_SEARCH_SECONDS] of [w], to cut between words. */
    private fun quietCut(w: FloatArray): Int {
        val frame = RATE / 20
        var best = w.size
        var bestEnergy = Double.MAX_VALUE
        var i = maxOf(0, w.size - RATE * CUT_SEARCH_SECONDS)
        while (i + frame <= w.size - RATE / 4) {
            var e = 0.0
            for (j in i until i + frame) e += w[j] * w[j]
            if (e < bestEnergy) { bestEnergy = e; best = i + frame / 2 }
            i += frame / 2
        }
        return best
    }

    /**
     * Transcribes [samples] trimmed to where you're actually talking. Whisper fed silence
     * makes things up ("the", "[", "Thank you."), so a stretch with no speech gives "" without
     * running it, and silence before and after the speech is cut down to [PAD_MS].
     */
    private fun pass(samples: FloatArray): String {
        val frame = RATE / 20
        val rms = DoubleArray(samples.size / frame) { f ->
            var e = 0.0
            for (j in f * frame until (f + 1) * frame) e += samples[j] * samples[j]
            Math.sqrt(e / frame)
        }
        if (rms.isEmpty()) return ""
        val floor = rms.sorted()[rms.size / 10]
        val threshold = maxOf(MIN_VOICE_RMS, minOf(floor * 3, 0.02))
        val first = rms.indexOfFirst { it > threshold }
        val last = rms.indexOfLast { it > threshold }
        val voiced = rms.count { it > threshold }
        val levels = "floor %.4f peak %.4f".format(floor, rms.maxOrNull() ?: 0.0)
        if (voiced < 2) {
            Log.i("QuestClaude", "whisper: ${samples.size * 1000 / RATE} ms, no speech ($levels)")
            return ""
        }
        val pad = RATE * PAD_MS / 1000
        val from = maxOf(0, first * frame - pad)
        val to = minOf(samples.size, (last + 1) * frame + pad)
        val speech = samples.copyOfRange(from, to)
        val t0 = System.nanoTime()
        val text = run(speech, audioCtx(speech.size))
        Log.i("QuestClaude", "whisper: ${speech.size * 1000 / RATE} of ${samples.size * 1000 / RATE} ms " +
            "in ${(System.nanoTime() - t0) / 1_000_000} ms ($levels): \"$text\"")
        return text
    }

    /**
     * Transcript so far of dictation [gen], or null if a newer start or a cancel replaced it.
     * Every pass uses an encoder window sized to the audio (much faster than Whisper's full
     * 30 s). Once the live window passes [WINDOW_SECONDS], it is cut at a pause, the part
     * before the cut is committed, and the rest starts the next window, so passes stay short
     * however long you talk and no word is split across two windows.
     */
    fun partial(gen: Int = generation): String? {
        val start: Int
        var samples: FloatArray
        synchronized(this) {
            if (gen != generation) return null
            start = windowStart
            samples = audio.copyOfRange(windowStart, size)
        }
        if (samples.size >= RATE * WINDOW_SECONDS) {
            val cut = quietCut(samples)
            val head = pass(samples.copyOfRange(0, cut))
            synchronized(this) {
                if (gen != generation) return null
                committed = join(committed, head)
                windowStart = start + cut
            }
            samples = samples.copyOfRange(cut, samples.size)
        }
        val text = if (samples.size < RATE / 2) "" else pass(samples)
        synchronized(this) {
            if (gen != generation) return null
            return join(committed, text)
        }
    }

    /**
     * Stops recording and returns the final transcript. Just one more live-style pass to pick up
     * the last words, not a slow full-window rerun of what you've already seen.
     */
    fun stopAndTranscribe(): String {
        recording = false
        recorder?.join()
        recorder = null
        return partial() ?: ""
    }

    fun cancel() {
        recording = false
        synchronized(this) { generation++ }
        recorder?.join()
        recorder = null
    }

    fun close() {
        cancel()
        if (handle != 0L) { WhisperNative.free(handle); handle = 0L }
    }
}
