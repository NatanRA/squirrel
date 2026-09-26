import Foundation

/// Swift face of Remux.c (embedded FFmpeg, remux only). Merges yt-dlp's
/// separate video/audio downloads and rewraps single files into a clean
/// container with correct duration headers.
enum Remuxer {
    /// FFmpeg muxer for each output extension the app writes.
    private static let muxers = [
        "mp4": "mp4", "m4a": "ipod", "mov": "mov", "mkv": "matroska", "webm": "webm",
        "mp3": "mp3", "ogg": "ogg", "opus": "ogg", "flac": "flac",
    ]

    static func canWrite(_ ext: String) -> Bool {
        muxers[ext.lowercased()] != nil
    }

    static func remux(_ inputs: [URL], to output: URL, metadata: [String: String] = [:]) async throws {
        guard let muxer = muxers[output.pathExtension.lowercased()] else {
            throw BridgeError(message: "Can't write .\(output.pathExtension) files")
        }
        let paths = inputs.map(\.path)
        let tags = metadata.filter { !$0.value.isEmpty }.flatMap { [$0.key, $0.value] }
        let outputPath = output.path

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let message = withCStrings(paths) { inputPointers in
                    withCStrings(tags) { tagPointers in
                        var error = [CChar](repeating: 0, count: 512)
                        let status = ytdl_remux(inputPointers, Int32(paths.count), outputPath, muxer,
                                                tagPointers, Int32(tags.count / 2), &error, error.count)
                        return status == 0 ? nil : String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
                if let message {
                    continuation.resume(throwing: BridgeError(message: "Couldn't finish the file: \(message)"))
                } else {
                    continuation.resume()
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
}
