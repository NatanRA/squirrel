import AVFoundation

/// Muxes separately downloaded video and audio streams into one MP4 without
/// re-encoding. This stands in for ffmpeg, which can't run on iOS; it only
/// works for codecs AVFoundation can put in MP4 (H.264/HEVC + AAC).
enum MediaMerger {
    /// `knownDuration` overrides the container's reported length when the caller
    /// has a trustworthy value (see `_sidx_duration` in ytdl_bridge.py).
    static func merge(video videoURL: URL, audio audioURL: URL, to outputURL: URL, knownDuration: Double? = nil) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw BridgeError(message: "Downloaded video stream has no video track")
        }
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first

        // AVFoundation reports YouTube's DASH streams at roughly twice their real
        // length (their headers are bogus), which would leave a frozen tail.
        var duration = try await videoAsset.load(.duration)
        if audioTrack != nil {
            duration = CMTimeMinimum(duration, try await audioAsset.load(.duration))
        }
        if let knownDuration, knownDuration > 0 {
            duration = CMTimeMinimum(duration, CMTime(seconds: knownDuration, preferredTimescale: 90_000))
        }
        let range = CMTimeRange(start: .zero, duration: duration)

        let composition = AVMutableComposition()
        let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        try compositionVideo?.insertTimeRange(range, of: videoTrack, at: .zero)
        compositionVideo?.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack {
            let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compositionAudio?.insertTimeRange(range, of: audioTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw BridgeError(message: "Could not create export session")
        }
        export.timeRange = range
        try? FileManager.default.removeItem(at: outputURL)
        try await export.export(to: outputURL, as: .mp4)
    }
}
