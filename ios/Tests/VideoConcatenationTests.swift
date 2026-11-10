// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AVFoundation
@testable import YunX

final class VideoConcatenationTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL { try XCTUnwrap(Bundle(for: VideoConcatenationTests.self).url(forResource: name, withExtension: "mp4")) }
    private func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url), track = try await asset.loadTracks(withMediaType: .video).first
        let video = try XCTUnwrap(track), range = try await video.load(.timeRange)
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.timeRange = range
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            times.append(CMTimeGetSeconds(time))
            if CMTimeCompare(time, range.start) >= 0, CMTimeCompare(time, CMTimeRangeGetEnd(range)) < 0 { count += 1 }
        }
        print("Synthetic decoded video timeline: start=\(CMTimeGetSeconds(range.start)), duration=\(CMTimeGetSeconds(range.duration)), pts=\(times), displayed=\(count)")
        XCTAssertEqual(reader.status, .completed); return count
    }
    func testRealH264SegmentsKeepAllDisplayedFramesAndDoubleDuration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture("synthetic-video"), output = folder.appendingPathComponent("joined.mp4")
        try await AVMediaAssembly.concatenate([source, source], output: output)
        let originalDuration = try await AVURLAsset(url: source).load(.duration), result = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(result), CMTimeGetSeconds(originalDuration) * 2, accuracy: 0.05)
        let originalFrames = try await frameCount(source), joinedFrames = try await frameCount(output)
        XCTAssertGreaterThan(originalFrames, 0); XCTAssertEqual(joinedFrames, originalFrames * 2)
    }
    func testAudioSurvivesSequentialConcatenation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4"), output = folder.appendingPathComponent("joined.mp4")
        try await AVMediaAssembly.merge(video: fixture("synthetic-video"), audio: fixture("synthetic-audio"), output: source)
        try await AVMediaAssembly.concatenate([source, source], output: output)
        let audio = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let duration = try await XCTUnwrap(audio.first).load(.timeRange).duration
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.5)
    }
    func testInvalidInputsAndExistingDestinationNeverProduceOrOverwriteOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("joined.mp4"), video = try fixture("synthetic-video"), audio = try fixture("synthetic-audio")
        do { try await AVMediaAssembly.concatenate([video, audio], output: output); XCTFail("Audio-only input must be rejected") } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        let sentinel = Data("existing-file".utf8); try sentinel.write(to: output)
        do { try await AVMediaAssembly.concatenate([video, video], output: output); XCTFail("Existing output must survive") } catch { XCTAssertEqual(try Data(contentsOf: output), sentinel) }
    }
    func testLegacyAssemblyRecordsAndNewOrderedPlansRemainDecodable() throws {
        let source = URL(string: "https://cdn.example.test/video.mp4")!
        var job = AssemblyJob(id: UUID(), video: source, audio: source, headers: [:], filename: "joined.mp4")
        let old = try JSONEncoder().encode(job)
        XCTAssertNil(try JSONDecoder().decode(AssemblyJob.self, from: old).segments)
        job.segments = [source, URL(string: "https://cdn.example.test/second.mp4")!]
        XCTAssertEqual(try JSONDecoder().decode(AssemblyJob.self, from: JSONEncoder().encode(job)).segments, job.segments)
    }
}
