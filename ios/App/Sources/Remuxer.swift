import Foundation
import os
import VideoToolbox

/// Swift face of Remux.c and Convert.c (embedded FFmpeg). Merges yt-dlp's separate video/audio
/// downloads and rewraps single files into a clean container with correct duration
/// headers, adding any subtitles as tracks. Also converts audio to MP3, and the only videos
/// it re-encodes are the ones Photos won't take (AV1, VP9), to HEVC.
enum Remuxer {
    /// A subtitle file (WebVTT or SubRip) to add to a video as a track.
    struct Subtitle {
        let file: URL
        /// ISO 639-2, like "eng"
        let language: String?
        /// What the player's subtitle menu shows, like "English"
        let name: String?
    }

    /// Video codecs Photos refuses, by FFmpeg's names, even on iPhones that play them (AV1)
    static let photosRefuses: Set<String> = ["av1", "vp9", "vp8"]

    /// What `convertToHEVC` can read here: VP9 anywhere (decoded in software), and AV1 where
    /// VideoToolbox decodes it (A17 Pro, M-series and later)
    static let convertibleCodecs: Set<String> =
        VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? ["vp9", "av1"] : ["vp9"]

    /// FFmpeg muxer for each output extension the app writes.
    private static let muxers = [
        "mp4": "mp4", "m4a": "ipod", "mov": "mov", "mkv": "matroska", "webm": "webm",
        "mp3": "mp3", "ogg": "ogg", "opus": "ogg", "flac": "flac",
    ]

    static func canWrite(_ ext: String) -> Bool {
        muxers[ext.lowercased()] != nil
    }

    /// Subtitles that can't be read are left out rather than failing the file.
    static func remux(
        _ inputs: [URL], to output: URL, subtitles: [Subtitle] = [], metadata: [String: String] = [:]
    ) async throws {
        guard let muxer = muxers[output.pathExtension.lowercased()] else {
            throw BridgeError(message: "Can't write .\(output.pathExtension) files")
        }
        let paths = inputs.map(\.path)
        let subtitlePaths = subtitles.map(\.file.path)
        let languages = subtitles.map(\.language)
        let names = subtitles.map(\.name)
        let tags = tags(metadata)
        let outputPath = output.path

        try await run(failure: "Couldn't finish the file") { error, size in
            withCStrings(paths) { inputPointers in
                withCStrings(subtitlePaths) { subtitlePointers in
                    withCStrings(languages) { languagePointers in
                        withCStrings(names) { namePointers in
                            withCStrings(tags) { tagPointers in
                                ytdl_remux_subtitled(
                                    inputPointers, Int32(paths.count),
                                    subtitlePointers, languagePointers, namePointers, Int32(subtitlePaths.count),
                                    outputPath, muxer, tagPointers, Int32(tags.count / 2), error, size)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Re-encodes the audio of `input` as an MP3 at `output`.
    static func convertToMP3(_ input: URL, to output: URL, metadata: [String: String] = [:]) async throws {
        let inputPath = input.path
        let outputPath = output.path
        let tags = tags(metadata)

        try await run(failure: "Couldn't make the MP3") { error, size in
            withCStrings(tags) { tagPointers in
                ytdl_convert_to_mp3(inputPath, outputPath, tagPointers, Int32(tags.count / 2), error, size)
            }
        }
    }

    /// FFmpeg's name for the codec of the file's video ("h264", "hevc", "av1", "vp9"), nil without one.
    static func videoCodec(of url: URL) -> String? {
        var codec = [CChar](repeating: 0, count: 32)
        guard ytdl_video_codec(url.path, &codec, codec.count) == 0 else { return nil }
        return String(decoding: codec.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// "AV1" for "av1", for messages.
    static func displayName(ofCodec codec: String) -> String {
        ["h264": "H.264", "hevc": "HEVC"][codec] ?? codec.uppercased()
    }

    /// Re-encodes an AV1 or VP9 video as HEVC in an MP4 at `output`, copying its audio and tags.
    /// Throws a cancelled `BridgeError` once `progress` is cancelled.
    static func convertToHEVC(_ input: URL, to output: URL, progress: ConversionProgress) async throws {
        let inputPath = input.path
        let outputPath = output.path

        try await run(failure: nil, cancelled: { progress.isCancelled }) { error, size in
            withExtendedLifetime(progress) {
                ytdl_convert_to_hevc(inputPath, outputPath, { context, fraction in
                    Unmanaged<ConversionProgress>.fromOpaque(context!).takeUnretainedValue().report(fraction) ? 1 : 0
                }, Unmanaged.passUnretained(progress).toOpaque(), error, size)
            }
        }
    }

    /// Key/value pairs for Remux.c, leaving out empty values.
    private static func tags(_ metadata: [String: String]) -> [String] {
        metadata.filter { !$0.value.isEmpty }.flatMap { [$0.key, $0.value] }
    }

    /// Runs a Remux.c call off the main thread; a non-zero status throws its error message, after
    /// `failure` if given, and marked cancelled when `cancelled` says it was.
    private static func run(
        failure: String?, cancelled: @escaping @Sendable () -> Bool = { false },
        _ call: @escaping @Sendable (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error = [CChar](repeating: 0, count: 512)
                let status = error.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
                if status == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    continuation.resume(throwing: BridgeError(
                        message: failure.map { "\($0): \(message)" } ?? message, cancelled: cancelled()))
                }
            }
        }
    }

    /// Calls `body` with a C array of C strings that live for the duration of the call.
    private static func withCStrings<T>(_ strings: [String], _ body: ([UnsafePointer<CChar>]) -> T) -> T {
        let copies = strings.map { strdup($0)! }
        defer { copies.forEach { free($0) } }
        return body(copies.map { UnsafePointer($0) })
    }

    /// The same, with NULL for nil.
    private static func withCStrings<T>(_ strings: [String?], _ body: ([UnsafePointer<CChar>?]) -> T) -> T {
        let copies = strings.map { $0.map { strdup($0)! } }
        defer { copies.forEach { free($0) } }
        return body(copies.map { $0.map { UnsafePointer($0) } })
    }
}

/// How far a conversion is, and whether to stop it: written from FFmpeg's thread, read by the app.
final class ConversionProgress: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (fraction: 0.0, cancelled: false))

    var fraction: Double { state.withLock { $0.fraction } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// Records how far it is; true once it should stop.
    fileprivate func report(_ fraction: Double) -> Bool {
        state.withLock {
            $0.fraction = fraction
            return $0.cancelled
        }
    }
}
