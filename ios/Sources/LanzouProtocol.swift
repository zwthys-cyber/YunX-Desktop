// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum LanzouProtocol {
    static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static func shareHost(_ host: String) -> Bool {
        host.range(of: #"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z]?|lan[zs]o[ux])\.(?:com|net|org|cn)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func safe(_ url: URL) -> Bool { url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) }
    static func first(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > group, let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func variable(_ name: String, html: String) -> String? {
        first(#"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*['"]([^'"]*)['"]"#, in: html)
    }
    static func input(_ name: String, html: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: name)
        return first(#"<input\b[^>]*name=['"]"# + name + #"['"][^>]*value=['"]([^'"]*)['"]"#, in: html) ?? first(#"<input\b[^>]*value=['"]([^'"]*)['"][^>]*name=['"]"# + name + #"['"]"#, in: html)
    }
    static func challenge(_ html: String) -> String? {
        guard let value = first(#"\barg1\s*=\s*['"]([0-9a-f]{40})['"]"#, in: html) else { return nil }
        let positions = [15,35,29,24,33,16,1,38,10,9,19,31,40,27,22,23,25,13,6,11,39,18,20,8,14,21,32,26,2,30,7,4,17,5,3,28,34,37,12,36]
        let chars = Array(value), mask = Array("3000176000856006061501533003690027800375")
        let rearranged = positions.map { chars[$0 - 1] }
        return stride(from: 0, to: 40, by: 2).map { i in
            let a = UInt8(String(rearranged[i...i + 1]), radix: 16)!, b = UInt8(String(mask[i...i + 1]), radix: 16)!
            return String(format: "%02x", a ^ b)
        }.joined()
    }
    static func rawID(_ id: String) throws -> String {
        let value = id.hasPrefix("d:") || id.hasPrefix("f:") ? String(id.dropFirst(2)) : id
        guard value == "-1" || value.range(of: "^[0-9]{1,20}$", options: .regularExpression) != nil else { throw CloudError.message("蓝奏文件标识无效。") }
        return value
    }
    static func size(_ text: String) -> Int64 {
        guard let number = first(#"([0-9]+(?:\.[0-9]+)?)\s*[kmgt]?"#, in: text), let value = Double(number), value.isFinite else { return 0 }
        let unit = first(#"[0-9]+(?:\.[0-9]+)?\s*([kmgt])"#, in: text)?.uppercased() ?? ""
        let power = ["K": 1, "M": 2, "G": 3, "T": 4][unit] ?? 0
        let bytes = value * pow(1024, Double(power))
        return bytes >= 0 && bytes < Double(Int64.max) ? Int64(bytes) : 0
    }
    static func cookies(_ text: String) -> [String: String] {
        text.split(separator: ";").reduce(into: [:]) { result, pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
    }
}
