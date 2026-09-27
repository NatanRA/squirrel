#include <jni.h>
#include <stdlib.h>

#include "Remux.h"

/// Copies a Java String[] into malloc'd C strings (NULL for null elements).
static const char **to_c_strings(JNIEnv *env, jobjectArray array, int *count) {
    *count = array ? (*env)->GetArrayLength(env, array) : 0;
    const char **strings = calloc(*count > 0 ? *count : 1, sizeof(char *));
    for (int i = 0; i < *count; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        if (!s) continue;
        strings[i] = (*env)->GetStringUTFChars(env, s, NULL);
        (*env)->DeleteLocalRef(env, s);
    }
    return strings;
}

static void release_c_strings(JNIEnv *env, jobjectArray array, const char **strings, int count) {
    for (int i = 0; i < count; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        if (!s) continue;
        (*env)->ReleaseStringUTFChars(env, s, strings[i]);
        (*env)->DeleteLocalRef(env, s);
    }
    free(strings);
}

/// Remuxer.remux(inputs, subtitles, languages, titles, output, muxer, metadataKeyValues): error
/// message, or null on success. languages and titles have one entry (or null) per subtitle.
__attribute__((visibility("default")))
JNIEXPORT jstring JNICALL Java_app_squirrel_Remuxer_remux(
        JNIEnv *env, jclass clazz, jobjectArray inputs, jobjectArray subtitles, jobjectArray languages,
        jobjectArray titles, jstring output, jstring muxer, jobjectArray metadata) {
    (void)clazz;
    int input_count, subtitle_count, language_count, title_count, metadata_count;
    const char **input_paths = to_c_strings(env, inputs, &input_count);
    const char **subtitle_paths = to_c_strings(env, subtitles, &subtitle_count);
    const char **subtitle_languages = to_c_strings(env, languages, &language_count);
    const char **subtitle_titles = to_c_strings(env, titles, &title_count);
    const char **tags = to_c_strings(env, metadata, &metadata_count);
    const char *output_path = (*env)->GetStringUTFChars(env, output, NULL);
    const char *format = (*env)->GetStringUTFChars(env, muxer, NULL);

    char error[512] = "";
    int status = ytdl_remux_subtitled(
        input_paths, input_count, subtitle_paths,
        language_count == subtitle_count ? subtitle_languages : NULL,
        title_count == subtitle_count ? subtitle_titles : NULL, subtitle_count,
        output_path, format, tags, metadata_count / 2, error, sizeof(error));

    (*env)->ReleaseStringUTFChars(env, muxer, format);
    (*env)->ReleaseStringUTFChars(env, output, output_path);
    release_c_strings(env, metadata, tags, metadata_count);
    release_c_strings(env, titles, subtitle_titles, title_count);
    release_c_strings(env, languages, subtitle_languages, language_count);
    release_c_strings(env, subtitles, subtitle_paths, subtitle_count);
    release_c_strings(env, inputs, input_paths, input_count);
    return status == 0 ? NULL : (*env)->NewStringUTF(env, error);
}

/// Remuxer.convertToMp3(input, output, metadataKeyValues): error message, or null on success.
__attribute__((visibility("default")))
JNIEXPORT jstring JNICALL Java_app_squirrel_Remuxer_convertToMp3(
        JNIEnv *env, jclass clazz, jstring input, jstring output, jobjectArray metadata) {
    (void)clazz;
    int metadata_count;
    const char **tags = to_c_strings(env, metadata, &metadata_count);
    const char *input_path = (*env)->GetStringUTFChars(env, input, NULL);
    const char *output_path = (*env)->GetStringUTFChars(env, output, NULL);

    char error[512] = "";
    int status = ytdl_convert_to_mp3(input_path, output_path, tags, metadata_count / 2, error, sizeof(error));

    (*env)->ReleaseStringUTFChars(env, output, output_path);
    (*env)->ReleaseStringUTFChars(env, input, input_path);
    release_c_strings(env, metadata, tags, metadata_count);
    return status == 0 ? NULL : (*env)->NewStringUTF(env, error);
}
