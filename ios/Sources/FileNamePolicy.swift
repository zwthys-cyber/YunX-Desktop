// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum FileNamePolicy {
    /// Leave room for the UUID appended when resolving a duplicate file.
    static func name(_ raw: String, maxBytes: Int = 200) -> String {
        let cleaned = raw.components(separatedBy: CharacterSet(charactersIn: "/\\:\0\n\r"))
            .joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return "download.bin" }
        let url = URL(fileURLWithPath: cleaned)
        let ext = url.pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 32 ? "." + ext : ""
        let stem = suffix.isEmpty ? cleaned : url.deletingPathExtension().lastPathComponent
        var output = ""
        let budget = max(16, maxBytes - suffix.utf8.count)
        var used = 0
        for character in stem {
            let count = String(character).utf8.count
            if used + count > budget { break }
            output.append(character)
            used += count
        }
        if output.isEmpty { output = "download" }
        return output + suffix
    }
}
