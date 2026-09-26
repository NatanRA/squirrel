#include <jni.h>
#include <stdlib.h>

#include "Remux.h"

/// Copies a Java String[] into malloc'd C strings.
static const char **to_c_strings(JNIEnv *env, jobjectArray array, int *count) {
    *count = array ? (*env)->GetArrayLength(env, array) : 0;
    const char **strings = calloc(*count > 0 ? *count : 1, sizeof(char *));
    for (int i = 0; i < *count; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        strings[i] = (*env)->GetStringUTFChars(env, s, NULL);
        (*env)->DeleteLocalRef(env, s);
    }
    return strings;
}

static void release_c_strings(JNIEnv *env, jobjectArray array, const char **strings, int count) {
    for (int i = 0; i < count; i++) {
        jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
        (*env)->ReleaseStringUTFChars(env, s, strings[i]);
        (*env)->DeleteLocalRef(env, s);
    }
    free(strings);
}

/// Remuxer.remux(inputs, output, muxer, metadataKeyValues): error message, or null on success.
__attribute__((visibility("default")))
JNIEXPORT jstring JNICALL Java_app_squirrel_Remuxer_remux(
        JNIEnv *env, jclass clazz, jobjectArray inputs, jstring output, jstring muxer, jobjectArray metadata) {
    (void)clazz;
    int input_count, metadata_count;
    const char **input_paths = to_c_strings(env, inputs, &input_count);
    const char **tags = to_c_strings(env, metadata, &metadata_count);
    const char *output_path = (*env)->GetStringUTFChars(env, output, NULL);
    const char *format = (*env)->GetStringUTFChars(env, muxer, NULL);

    char error[512] = "";
    int status = ytdl_remux(input_paths, input_count, output_path, format,
                            tags, metadata_count / 2, error, sizeof(error));

    (*env)->ReleaseStringUTFChars(env, muxer, format);
    (*env)->ReleaseStringUTFChars(env, output, output_path);
    release_c_strings(env, metadata, tags, metadata_count);
    release_c_strings(env, inputs, input_paths, input_count);
    return status == 0 ? NULL : (*env)->NewStringUTF(env, error);
}
