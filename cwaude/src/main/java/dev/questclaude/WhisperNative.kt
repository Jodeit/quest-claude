package dev.questclaude

// Stays in dev.questclaude: the JNI symbols in app/src/main/cpp/qcwhisper.c are named for it.
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
