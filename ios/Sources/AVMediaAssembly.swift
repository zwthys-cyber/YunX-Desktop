// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation

/// Stream-copy compatible local video/audio tracks into MP4 using public iOS APIs.
enum AVMediaAssembly {
    static func concatenate(_ files: [URL], output: URL) async throws {
        guard (2...200).contains(files.count) else { throw CloudError.message("拼接需要 2–200 个按顺序排列的片段。") }
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CloudError.message("输出文件已存在，拒绝覆盖。") }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CloudError.message("无法创建拼接视频轨道。") }
        var sound: AVMutableCompositionTrack?
        var cursor = CMTime.zero
        var dimensions: CMVideoDimensions?
        var codec: FourCharCode?
        var transform: CGAffineTransform?
        var audioPresent: Bool?
        for file in files {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: file)
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                  let format = try await video.load(.formatDescriptions).first else { throw CloudError.message("片段缺少可用视频轨道。") }
            let range = try await video.load(.timeRange), orientation = try await video.load(.preferredTransform)
            let shape = CMVideoFormatDescriptionGetDimensions(format), subtype = CMFormatDescriptionGetMediaSubType(format)
            guard range.duration.isNumeric, CMTimeCompare(range.duration, .zero) > 0 else { throw CloudError.message("片段时长无效。") }
            if let dimensions, let codec, let transform {
                guard dimensions.width == shape.width, dimensions.height == shape.height, codec == subtype, transform == orientation else { throw CloudError.message("片段编码、尺寸或方向不同，不能无损拼接。") }
            } else { dimensions = shape; codec = subtype; transform = orientation; picture.preferredTransform = orientation }
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            if let audioPresent { guard audioPresent == (audio != nil) else { throw CloudError.message("部分片段缺少音频，已停止以免保存不完整结果。") } }
            else { audioPresent = audio != nil }
            try picture.insertTimeRange(range, of: video, at: cursor)
            if let audio {
                if sound == nil { sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                guard let sound else { throw CloudError.message("无法创建拼接音频轨道。") }
                let audioRange = try await audio.load(.timeRange)
                let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                guard overlap.duration.isNumeric, CMTimeCompare(overlap.duration, .zero) > 0,
                      abs(CMTimeGetSeconds(audioRange.duration) - CMTimeGetSeconds(range.duration)) <= 1 else { throw CloudError.message("片段音视频时长不一致。") }
                let offset = CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start))
                try sound.insertTimeRange(overlap, of: audio, at: offset)
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough), exporter.supportedFileTypes.contains(.mp4) else { throw CloudError.message("当前片段不支持 iOS 无损 MP4 拼接。") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        exporter.outputURL = output; exporter.outputFileType = .mp4; exporter.shouldOptimizeForNetworkUse = true
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    exporter.exportAsynchronously {
                        if exporter.status == .completed { continuation.resume() }
                        else if exporter.status == .cancelled { continuation.resume(throwing: CancellationError()) }
                        else { continuation.resume(throwing: CloudError.message("iOS 拼接失败，原片段已保留。")) }
                    }
                }
            } onCancel: { exporter.cancelExport() }
            try Task.checkCancellation()
            let result = AVURLAsset(url: output)
            let videos = try await result.loadTracks(withMediaType: .video), audios = try await result.loadTracks(withMediaType: .audio)
            let duration = try await result.load(.duration), playable = try await result.load(.isPlayable)
            guard playable, !videos.isEmpty, audioPresent != true || !audios.isEmpty, duration.isNumeric,
                  abs(CMTimeGetSeconds(duration) - CMTimeGetSeconds(cursor)) <= 0.25 else { throw CloudError.message("拼接结果轨道或总时长不完整，已拒绝保存。") }
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
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
