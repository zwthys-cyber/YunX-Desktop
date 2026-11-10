// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum FormEncoding {
    static func encode(_ text: String, literalColon: Bool = false) -> String {
        text.utf8.map { byte in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 95, 46, 42: return String(UnicodeScalar(byte))
            case 58 where literalColon: return ":"
            case 32: return "+"
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }
    static func query(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
    }
    static func data(_ values: [String: String]) -> Data { Data(query(values).utf8) }
}
