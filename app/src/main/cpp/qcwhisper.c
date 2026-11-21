// JNI bridge to whisper.cpp for on-device dictation.
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <android/log.h>
#include "whisper.h"

#define TAG "qcwhisper"

JNIEXPORT jlong JNICALL
Java_dev_questclaude_WhisperNative_init(JNIEnv *env, jobject thiz, jstring path) {
    const char *p = (*env)->GetStringUTFChars(env, path, NULL);
    struct whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;
    cp.flash_attn = true;
    struct whisper_context *ctx = whisper_init_from_file_with_params(p, cp);
    if (!ctx) __android_log_print(ANDROID_LOG_ERROR, TAG, "failed to load model %s", p);
    (*env)->ReleaseStringUTFChars(env, path, p);
    return (jlong) (intptr_t) ctx;
}

// Returns the transcript as UTF-8 bytes (whisper can emit 4-byte UTF-8, which NewStringUTF
// doesn't accept), or null on failure.
JNIEXPORT jbyteArray JNICALL
Java_dev_questclaude_WhisperNative_transcribe(JNIEnv *env, jobject thiz, jlong handle,
                                              jfloatArray samples, jint threads, jint audio_ctx) {
    struct whisper_context *ctx = (struct whisper_context *) (intptr_t) handle;
    if (!ctx) return NULL;

    struct whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.n_threads = threads;
    wp.language = "en";
    wp.translate = false;
    wp.no_context = true;
    wp.no_timestamps = true;
    wp.print_special = false;
    wp.print_progress = false;
    wp.print_realtime = false;
    wp.print_timestamps = false;
    // Live partials pass a smaller encoder window (0 = the full 30 s), which is much faster.
    wp.audio_ctx = audio_ctx;
    wp.single_segment = audio_ctx > 0;
    // No temperature fallback: a low-confidence pass would otherwise re-run decoding up to 5
    // more times, which is most of the lag on hard audio. The next live pass corrects it anyway.
    wp.temperature_inc = 0.0f;

    jsize n = (*env)->GetArrayLength(env, samples);
    // About 5 tokens a second is fast talk; past that Whisper is looping, so stop it there.
    // (Was 6/s + 16, which left room for a short phrase to come out two and a half times.)
    if (audio_ctx > 0) wp.max_tokens = (int) ((int64_t) n * 5 / 16000) + 10;
    jfloat *pcm = (*env)->GetFloatArrayElements(env, samples, NULL);
    int rc = whisper_full(ctx, wp, pcm, n);
    (*env)->ReleaseFloatArrayElements(env, samples, pcm, JNI_ABORT);
    if (rc != 0) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "whisper_full failed: %d", rc);
        return NULL;
    }

    size_t len = 0;
    int segs = whisper_full_n_segments(ctx);
    for (int i = 0; i < segs; i++) len += strlen(whisper_full_get_segment_text(ctx, i));
    char *buf = malloc(len + 1);
    if (!buf) return NULL;
    buf[0] = 0;
    for (int i = 0; i < segs; i++) strcat(buf, whisper_full_get_segment_text(ctx, i));

    jbyteArray out = (*env)->NewByteArray(env, (jsize) len);
    (*env)->SetByteArrayRegion(env, out, 0, (jsize) len, (const jbyte *) buf);
    free(buf);
    return out;
}

JNIEXPORT void JNICALL
Java_dev_questclaude_WhisperNative_free(JNIEnv *env, jobject thiz, jlong handle) {
    struct whisper_context *ctx = (struct whisper_context *) (intptr_t) handle;
    if (ctx) whisper_free(ctx);
}
