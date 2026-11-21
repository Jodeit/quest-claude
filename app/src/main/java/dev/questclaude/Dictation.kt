package dev.questclaude

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
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
        /** Whisper's markers for non-speech, e.g. [BLANK_AUDIO], (wind blowing). */
        /** Audio past this is transcribed for good and dropped from the live window. */
        private const val WINDOW_SECONDS = 20
        private val NON_SPEECH = Regex("""\[[^\]]*]|\([^)]*\)""")
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
    fun start() {
        if (recording) return
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        val rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT,
            maxOf(min, RATE * 4),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release(); error("couldn't open the microphone")
        }
        synchronized(this) { size = 0; windowStart = 0; committed = "" }
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
    }

    private fun window(): FloatArray = synchronized(this) { audio.copyOfRange(windowStart, size) }

    private fun run(samples: FloatArray, audioCtx: Int): String {
        load()
        val bytes = WhisperNative.transcribe(handle, samples, THREADS, audioCtx) ?: error("transcription failed")
        return clean(String(bytes, Charsets.UTF_8))
    }

    private fun clean(s: String) = s.replace(NON_SPEECH, "").replace(Regex("\\s+"), " ").trim()

    private fun join(a: String, b: String) = listOf(a, b).filter { it.isNotEmpty() }.joinToString(" ")

    /**
     * Transcript so far, while recording. Uses a shortened encoder window sized to the audio
     * (much faster than the full 30 s); once the live window passes [WINDOW_SECONDS] it is
     * transcribed in full, committed, and a new window starts.
     */
    fun partial(): String {
        val samples = window()
        if (samples.size < RATE / 2) return committed
        if (samples.size >= RATE * WINDOW_SECONDS) {
            committed = join(committed, run(samples, 0))
            synchronized(this) { windowStart += samples.size }
            return committed
        }
        // 50 encoder frames per second of audio, plus margin, rounded up to 64.
        val ctx = ((samples.size * 50 / RATE + 64 + 63) / 64 * 64).coerceAtMost(1500)
        return join(committed, run(samples, ctx))
    }

    /** Stops recording and returns the final transcript ("" if nothing was said). */
    fun stopAndTranscribe(): String {
        recording = false
        recorder?.join()
        recorder = null
        val samples = window()
        if (samples.size < RATE / 2) return committed
        return join(committed, run(samples, 0))
    }

    fun cancel() {
        recording = false
        recorder?.join()
        recorder = null
    }

    fun close() {
        cancel()
        if (handle != 0L) { WhisperNative.free(handle); handle = 0L }
    }
}
