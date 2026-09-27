import Foundation

/// Swift face of Remux.c (embedded FFmpeg). Merges yt-dlp's separate video/audio
/// downloads and rewraps single files into a clean container with correct duration
/// headers, adding any subtitles as tracks. Also converts audio to MP3.
enum Remuxer {
    /// A subtitle file (WebVTT or SubRip) to add to a video as a track.
    struct Subtitle {
        let file: URL
        /// ISO 639-2, like "eng"
        let language: String?
        /// What the player's subtitle menu shows, like "English"
        let name: String?
    }

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

    /// Key/value pairs for Remux.c, leaving out empty values.
    private static func tags(_ metadata: [String: String]) -> [String] {
        metadata.filter { !$0.value.isEmpty }.flatMap { [$0.key, $0.value] }
    }

    /// Runs a Remux.c call off the main thread; a non-zero status throws its error message.
    private static func run(
        failure: String, _ call: @escaping @Sendable (UnsafeMutablePointer<CChar>, Int) -> Int32
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error = [CChar](repeating: 0, count: 512)
                let status = error.withUnsafeMutableBufferPointer { call($0.baseAddress!, $0.count) }
                if status == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    continuation.resume(throwing: BridgeError(message: "\(failure): \(message)"))
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
