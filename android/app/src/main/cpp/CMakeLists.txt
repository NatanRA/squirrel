cmake_minimum_required(VERSION 3.22.1)
project(ytdlremux C)

# Remuxer shared with the iOS app, linked against the minimal FFmpeg (and LAME, for
# MP3s) built by scripts/build_ffmpeg.sh (static, LGPL).
set(SHARED_NATIVE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../shared/native)
set(FFMPEG ${CMAKE_CURRENT_SOURCE_DIR}/ffmpeg/${ANDROID_ABI})

if(NOT EXISTS ${FFMPEG}/lib/libmp3lame.a)
    message(FATAL_ERROR "FFmpeg for ${ANDROID_ABI} is missing: run android/scripts/build_ffmpeg.sh")
endif()

add_library(ytdlremux SHARED jni_remux.c ${SHARED_NATIVE}/Remux.c)
target_include_directories(ytdlremux PRIVATE ${SHARED_NATIVE} ${FFMPEG}/include)
target_link_libraries(ytdlremux
    ${FFMPEG}/lib/libavformat.a ${FFMPEG}/lib/libavcodec.a ${FFMPEG}/lib/libswresample.a
    ${FFMPEG}/lib/libavutil.a ${FFMPEG}/lib/libmp3lame.a
    z log m)
# Keep only the JNI entry point exported
set_target_properties(ytdlremux PROPERTIES C_VISIBILITY_PRESET hidden)
target_link_options(ytdlremux PRIVATE -Wl,--exclude-libs,ALL -Wl,--gc-sections)
