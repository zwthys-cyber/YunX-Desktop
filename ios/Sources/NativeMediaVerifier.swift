// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Yunxengine

final class IOSMediaVerifier: NSObject, YunxengineMediaVerifierProtocol, @unchecked Sendable {
    private let root: URL
    init(root: URL) { self.root = root; super.init() }

    func verify(_ path: String?, kind: String?) -> Int {
        guard let path, let kind, ["image", "video"].contains(kind) else { return 2 }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        // Each native task owns one UUID child; never inspect other app files.
        let parent = file.deletingLastPathComponent()
        guard UUID(uuidString: parent.lastPathComponent) != nil,
              parent.deletingLastPathComponent().resolvingSymlinksInPath() == root.resolvingSymlinksInPath(),
              parent.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent(parent.lastPathComponent, isDirectory: true),
              file.resolvingSymlinksInPath().deletingLastPathComponent() == parent.resolvingSymlinksInPath() else { return 2 }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { return 2 }
            // Probe readability separately: protected/unavailable storage is retryable.
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            _ = try reader.read(upToCount: 1)
            do {
                _ = try MediaFileValidation.filename(file.lastPathComponent, file: file, kind: kind, mime: nil)
                return 1
            } catch is CloudError { return 2 }
            catch { return 0 }
        } catch { return 0 }
    }
}
