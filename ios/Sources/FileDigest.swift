// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import CryptoKit

enum FileDigest {
    /// Stream the file so large downloads do not have to fit in memory.
    static func sha256(_ url: URL) throws -> String {
        // URL resource values can be cached across separate calls for the same URL.
        // Read fresh filesystem attributes before and after hashing instead.
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            digest.update(data: data)
        }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
              (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date),
              (before[.systemFileNumber] as? NSNumber) == (after[.systemFileNumber] as? NSNumber) else {
            throw CloudError.message("文件在计算期间发生变化，请重新计算。")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
