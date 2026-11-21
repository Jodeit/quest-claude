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
        val words = s.replace(NON_SPEECH, "").replace(Regex("\\s+"), " ").trim()
        return "$words ".replace(LOOP, "$1").trim()
    }

    private fun join(a: String, b: String) = listOf(a, b).filter { it.isNotEmpty() }.joinToString(" ")

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

    private fun pass(samples: FloatArray): String {
        val t0 = System.nanoTime()
        val text = run(samples, audioCtx(samples.size))
        Log.i("QuestClaude", "whisper: ${samples.size * 1000 / RATE} ms of audio in " +
            "${(System.nanoTime() - t0) / 1_000_000} ms")
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
