// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation

/// Stream-copy compatible local video/audio tracks into MP4 using public iOS APIs.
enum AVMediaAssembly {
    static func merge(video: URL, audio: URL, output: URL) async throws {
        try Task.checkCancellation()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw CloudError.message("分轨文件缺少视频或音频轨道，已停止合轨。")
        }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        guard videoRange.duration.isNumeric, audioRange.duration.isNumeric,
              CMTimeCompare(videoRange.duration, .zero) > 0, CMTimeCompare(audioRange.duration, .zero) > 0 else {
            throw CloudError.message("分轨文件时长无效。")
        }
        guard abs(CMTimeGetSeconds(videoRange.duration) - CMTimeGetSeconds(audioRange.duration)) <= 1 else {
            throw CloudError.message("音视频时长明显不一致，已停止合轨。")
        }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CloudError.message("无法创建合轨轨道。")
        }
        try picture.insertTimeRange(videoRange, of: videoTrack, at: .zero)
        picture.preferredTransform = try await videoTrack.load(.preferredTransform)
        let audioDuration = CMTimeCompare(audioRange.duration, videoRange.duration) < 0 ? audioRange.duration : videoRange.duration
        try sound.insertTimeRange(CMTimeRange(start: audioRange.start, duration: audioDuration), of: audioTrack, at: .zero)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else { throw CloudError.message("当前音视频编码不支持 iOS 无损 MP4 合轨。") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) { throw CloudError.message("输出文件已存在，拒绝覆盖。") }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    exporter.exportAsynchronously {
                        if exporter.status == .completed { continuation.resume() }
                        else if exporter.status == .cancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: CloudError.message("iOS 合轨失败，分轨文件保留以便重试。")) }
                    }
                }
            } onCancel: { exporter.cancelExport() }
            try Task.checkCancellation()
            let merged = AVURLAsset(url: output)
            let outputVideo = try await merged.loadTracks(withMediaType: .video)
            let outputAudio = try await merged.loadTracks(withMediaType: .audio)
            guard !outputVideo.isEmpty, !outputAudio.isEmpty else {
                throw CloudError.message("合轨结果缺少音频或视频，已拒绝保存。")
            }
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
