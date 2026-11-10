// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AVFoundation
@testable import YunX

final class AVAssemblyTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: AVAssemblyTests.self).url(forResource: name, withExtension: "mp4"))
    }
    func testRealH264AndAACAreMergedIntoPlayableMP4() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("merged.mp4")
        try await AVMediaAssembly.merge(video: fixture("synthetic-video"), audio: fixture("synthetic-audio"), output: output)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0.2)
        XCTAssertLessThan(CMTimeGetSeconds(duration), 0.6)
    }
    func testMissingAudioAndExistingOutputAreRejected() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("merged.mp4")
        do {
            try await AVMediaAssembly.merge(video: fixture("synthetic-video"), audio: fixture("synthetic-video"), output: output)
            XCTFail("Expected missing audio rejection")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
        let original = Data("existing-user-file".utf8)
        try original.write(to: output)
        do {
            try await AVMediaAssembly.merge(video: fixture("synthetic-video"), audio: fixture("synthetic-audio"), output: output)
            XCTFail("Expected overwrite rejection")
        } catch { XCTAssertEqual(try Data(contentsOf: output), original) }
    }
}
