// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import YunX

final class LivePhotoTests: XCTestCase {
    private func fixture() throws -> URL { try XCTUnwrap(Bundle(for: LivePhotoTests.self).url(forResource: "synthetic-video", withExtension: "mp4")) }
    private func still(_ output: URL, size: CGSize) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: max(1, Int(size.width)), height: max(1, Int(size.height)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        let image = try XCTUnwrap(context.makeImage()), destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func testGeneratedPairIsRecognizedByPhotoKitAndHasMatchingIdentifiers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(), motion = folder.appendingPathComponent("source.mp4"), photo = folder.appendingPathComponent("source.jpg")
        try await AVMediaAssembly.concatenate(Array(repeating: source, count: 8), output: motion)
        let track = try await AVURLAsset(url: source).loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        try still(photo, size: size)
        let jpeg = folder.appendingPathComponent("paired.jpg"), movie = folder.appendingPathComponent("paired.mov"), identifier = UUID().uuidString
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await LivePhotoAssembly.create(image: photo, video: motion, photoOutput: jpeg, movieOutput: movie, identifier: identifier) }
            group.addTask { try await Task.sleep(for: .seconds(30)); throw CloudError.message("PhotoKit local resource validation timed out") }
            _ = try await group.next(); group.cancelAll()
        }
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        XCTAssertEqual((properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any])?["17"] as? String, identifier)
        let asset = AVURLAsset(url: movie), metadata = try await asset.load(.metadata)
        let item = try XCTUnwrap(metadata.first { $0.identifier?.rawValue == "mdta/com.apple.quicktime.content.identifier" })
        let movieIdentifier = try await item.load(.stringValue)
        XCTAssertEqual(movieIdentifier, identifier)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(metadataTracks.count, 1)
        let duration = try await asset.load(.duration), original = try await AVURLAsset(url: motion).load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), CMTimeGetSeconds(original), accuracy: 0.1)
    }
    func testInvalidImageNeverLeavesPartialPair() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("bad.jpg"), jpeg = folder.appendingPathComponent("out.jpg"), movie = folder.appendingPathComponent("out.mov")
        try Data("not-an-image".utf8).write(to: input)
        do { try await LivePhotoAssembly.create(image: input, video: fixture(), photoOutput: jpeg, movieOutput: movie, identifier: UUID().uuidString); XCTFail("Invalid photo must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
    }
    func testExistingUserOutputIsPreserved() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let jpeg = folder.appendingPathComponent("existing.jpg"), movie = folder.appendingPathComponent("out.mov"), sentinel = Data("existing-user-file".utf8)
        try sentinel.write(to: jpeg)
        do { try await LivePhotoAssembly.create(image: jpeg, video: fixture(), photoOutput: jpeg, movieOutput: movie, identifier: UUID().uuidString); XCTFail("Existing output must not be overwritten") } catch { }
        XCTAssertEqual(try Data(contentsOf: jpeg), sentinel); XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
    }
    func testCancelledRequestDoesNotStartPhotoProcessing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try fixture(), jpeg = folder.appendingPathComponent("out.jpg"), movie = folder.appendingPathComponent("out.mov")
        let task = Task { while !Task.isCancelled { await Task.yield() }; try await LivePhotoAssembly.create(image: source, video: source, photoOutput: jpeg, movieOutput: movie, identifier: UUID().uuidString) }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation expected") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: jpeg.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path))
    }
}
