// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

enum FileDigest {
    /// Stream the file so large downloads do not have to fit in memory.
    static func sha256(_ url: URL) throws -> String {
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        var refreshed = url
        refreshed.removeAllCachedResourceValues()
        let after = try refreshed.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
            throw CloudError.message("文件在计算期间发生变化，请重新计算。")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
