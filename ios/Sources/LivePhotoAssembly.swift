// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import Photos

private final class LivePhotoRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PHLivePhoto, Error>?
    private var requestID: PHLivePhotoRequestID?
    private var finished = false
    func begin(_ continuation: CheckedContinuation<PHLivePhoto, Error>) {
        lock.lock(); defer { lock.unlock() }
        if finished { continuation.resume(throwing: CancellationError()) } else { self.continuation = continuation }
    }
    func bind(_ id: PHLivePhotoRequestID) {
        lock.lock(); let shouldCancel = finished; if !finished { requestID = id }; lock.unlock()
        if shouldCancel { PHLivePhoto.cancelRequest(withRequestID: id) }
    }
    func finish(_ result: Result<PHLivePhoto, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let continuation = self.continuation; self.continuation = nil; requestID = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        lock.lock(); let id = requestID; lock.unlock()
        if let id { PHLivePhoto.cancelRequest(withRequestID: id) }
        finish(.failure(CancellationError()))
    }
}

enum LivePhotoAssembly {
    static func preview(photo: URL, movie: URL) async throws -> PHLivePhoto {
        let request = LivePhotoRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.begin(continuation)
                let id = PHLivePhoto.request(withResourceFileURLs: [photo, movie], placeholderImage: nil, targetSize: CGSize(width: 800, height: 800), contentMode: .aspectFit) { result, info in
                    if info[PHLivePhotoInfoIsDegradedKey] as? Bool == true { return }
                    if let result { request.finish(.success(result)) }
                    else { request.finish(.failure(CloudError.message("系统未识别此动态照片配对，原素材已保留。"))) }
                }
                request.bind(id)
            }
        } onCancel: { request.cancel() }
    }
    static func create(image: URL, video: URL, photoOutput: URL, movieOutput: URL, identifier: String) async throws {
        guard UUID(uuidString: identifier) != nil, photoOutput != movieOutput,
              !FileManager.default.fileExists(atPath: photoOutput.path), !FileManager.default.fileExists(atPath: movieOutput.path) else { throw CloudError.message("动态照片标识或输出路径无效，拒绝覆盖已有文件。") }
        try Task.checkCancellation()
        do {
            try writePhoto(image, output: photoOutput, identifier: identifier)
            try await writeMovie(video, output: movieOutput, identifier: identifier)
            try Task.checkCancellation()
            _ = try await preview(photo: photoOutput, movie: movieOutput)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: photoOutput); try? FileManager.default.removeItem(at: movieOutput); throw error
        }
    }
    private static func writePhoto(_ input: URL, output: URL, identifier: String) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0,
              var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.int64Value > 0, height.int64Value > 0, width.int64Value <= 16384, height.int64Value <= 16384,
              width.int64Value * height.int64Value <= 24_000_000 else { throw CloudError.message("动态照片静图无效或超过 2400 万像素处理上限。") }
        var maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        maker["17"] = identifier; properties[kCGImagePropertyMakerAppleDictionary as String] = maker
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.95
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw CloudError.message("无法创建动态照片静图。") }
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CloudError.message("动态照片静图写入失败。") }
    }
    private static func writeMovie(_ source: URL, output: URL, identifier: String) async throws {
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, audios.count <= 1, let video = videos.first else { throw CloudError.message("动态照片视频轨道无效。") }
        let range = try await video.load(.timeRange)
        guard range.start.isNumeric, range.duration.isNumeric, CMTimeGetSeconds(range.duration) > 0, CMTimeGetSeconds(range.duration) <= 60 else { throw CloudError.message("动态照片视频需为不超过 60 秒的有效片段。") }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let reader = try AVAssetReader(asset: asset), writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        reader.timeRange = range
        let contentID = AVMutableMetadataItem(); contentID.keySpace = .quickTimeMetadata; contentID.key = "com.apple.quicktime.content.identifier" as NSString; contentID.value = identifier as NSString; contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentID]
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in videos + audios {
            let mediaType = track.mediaType, descriptions = try await track.load(.formatDescriptions)
            guard let hint = descriptions.first else { throw CloudError.message("动态照片视频缺少格式信息。") }
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            let trackInput = AVAssetWriterInput(mediaType: mediaType, outputSettings: nil, sourceFormatHint: hint)
            trackInput.expectsMediaDataInRealTime = false
            if mediaType == .video { trackInput.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(trackOutput), writer.canAdd(trackInput) else { throw CloudError.message("当前视频编码不能用于动态照片无损封装。") }
            reader.add(trackOutput); writer.add(trackInput); pairs.append((trackOutput, trackInput))
        }
        var description: CMFormatDescription?
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw CloudError.message("无法创建动态照片时间标记。") }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw CloudError.message("无法写入动态照片时间轨道。") }; writer.add(metadataInput)
        do {
            guard writer.startWriting(), reader.startReading() else { throw CloudError.message("动态照片无损封装无法启动。") }
            writer.startSession(atSourceTime: range.start)
            let stillTime = AVMutableMetadataItem(); stillTime.keySpace = .quickTimeMetadata; stillTime.key = "com.apple.quicktime.still-image-time" as NSString; stillTime.value = NSNumber(value: Int8(0)); stillTime.dataType = kCMMetadataBaseDataType_SInt8 as String
            let sampleDuration = CMTimeMinimum(range.duration, CMTime(value: 1, timescale: 30))
            let group = AVTimedMetadataGroup(items: [stillTime], timeRange: CMTimeRange(start: range.start, duration: sampleDuration))
            guard adaptor.append(group) else { throw CloudError.message("动态照片时间标记写入失败。") }; metadataInput.markAsFinished()
            var remaining = Set(pairs.indices)
            while !remaining.isEmpty {
                try Task.checkCancellation()
                guard writer.status == .writing, reader.status != .failed, reader.status != .cancelled else { throw CloudError.message("动态照片视频写入失败。") }
                var advanced = false
                for index in Array(remaining) {
                    let (output, input) = pairs[index]
                    guard input.isReadyForMoreMediaData else { continue }
                    advanced = true
                    if let sample = output.copyNextSampleBuffer() {
                        guard input.append(sample) else { throw CloudError.message("动态照片视频样本写入失败。") }
                    } else { input.markAsFinished(); remaining.remove(index) }
                }
                if !advanced { try await Task.sleep(for: .milliseconds(5)) }
            }
            guard reader.status == .completed else { throw CloudError.message("动态照片素材读取不完整。") }
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw CloudError.message("动态照片视频封装未完成。") }
        } catch { reader.cancelReading(); writer.cancelWriting(); throw error }
    }
}
