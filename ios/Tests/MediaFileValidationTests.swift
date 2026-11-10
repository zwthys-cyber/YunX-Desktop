// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class MediaFileValidationTests: XCTestCase {
    func testActualImageContainerDeterminesExtension() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/sOkAAAAASUVORK5CYII="))
        try png.write(to: file)
        XCTAssertEqual(try MediaFileValidation.filename("平台图.jpg", file: file, kind: "image", mime: "application/octet-stream"), "平台图.png")
        try Data("<html>verification</html>".utf8).write(to: file)
        XCTAssertThrowsError(try MediaFileValidation.filename("image.jpg", file: file, kind: "image", mime: "image/jpeg"))
    }
    func testVideoErrorPagesAndPlaylistsCannotBecomeCompletedMP4() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for response in ["<html>error</html>", "{\"error\":1}", "#EXTM3U\npart.ts", ""] {
            try Data(response.utf8).write(to: file)
            XCTAssertThrowsError(try MediaFileValidation.filename("movie.mp4", file: file, kind: "video", mime: "application/octet-stream"))
        }
        // Generic file downloads keep their original behavior; this is a media-specific gate.
        XCTAssertEqual(try MediaFileValidation.filename("document.txt", file: file, kind: nil, mime: "text/plain"), "document.txt")
    }
}
