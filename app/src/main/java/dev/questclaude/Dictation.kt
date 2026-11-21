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
    external fun transcribe(ctx: Long, samples: FloatArray, threads: Int): ByteArray?
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
        private val NON_SPEECH = Regex("""\[[^\]]*]|\([^)]*\)""")
    }

    private val modelFile = File(ctx.filesDir, MODEL_NAME)
    @Volatile private var handle = 0L
    @Volatile var recording = false
        private set
    private var recorder: Thread? = null
    private var audio = FloatArray(RATE * 30)
    private var size = 0

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
        size = 0
        recording = true
        recorder = Thread {
            val chunk = FloatArray(RATE / 10)
            rec.startRecording()
            try {
                while (recording && size < RATE * MAX_SECONDS) {
                    val n = rec.read(chunk, 0, chunk.size, AudioRecord.READ_BLOCKING)
                    if (n <= 0) continue
                    if (size + n > audio.size) audio = audio.copyOf(audio.size * 2)
                    System.arraycopy(chunk, 0, audio, size, n)
                    size += n
                }
            } finally {
                rec.stop(); rec.release()
            }
        }.apply { name = "dictation-mic"; start() }
    }

    /** Stops recording and returns the transcript ("" if nothing was said). */
    fun stopAndTranscribe(): String {
        recording = false
        recorder?.join()
        recorder = null
        if (size < RATE / 2) return ""
        load()
        val bytes = WhisperNative.transcribe(handle, audio.copyOf(size), THREADS)
            ?: error("transcription failed")
        return String(bytes, Charsets.UTF_8).replace(NON_SPEECH, "").replace(Regex("\\s+"), " ").trim()
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
