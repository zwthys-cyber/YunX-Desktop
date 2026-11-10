// SPDX-License-Identifier: AGPL-3.0-only
// Wire format ported from desktop C139Api.kt.
import Foundation
import CryptoKit
import Security
import CommonCrypto
import zlib

enum C139Protocol {
    static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let mobileAgent = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"
    private static let key = Array("PVGDwmcvfs1uV3d1".utf8)
    private static func md5(_ text: String) -> String { Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func sign(_ body: String, timestamp: String, random: String) -> String {
        let encoded = body.utf8.map { byte -> String in
            switch byte {
            case 48...57, 65...90, 97...122, 45, 95, 46, 33, 39, 40, 41, 42: return String(UnicodeScalar(byte))
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
        let sorted = String(encoded.sorted())
        return md5(md5(Data(sorted.utf8).base64EncodedString()) + md5(timestamp + ":" + random)).uppercased()
    }
    static func signHeader(_ body: String) -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 8 * 3600); format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = format.string(from: Date())
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let random = String((0..<16).map { _ in pool.randomElement()! })
        return timestamp + "," + random + "," + sign(body, timestamp: timestamp, random: random)
    }
    private static func crypt(_ input: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard iv.count == 16, input.count <= 2_097_152 else { throw CloudError.message("139 加密数据长度无效。") }
        var output = [UInt8](repeating: 0, count: input.count + 16), count = 0
        let capacity = output.count
        let result = key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in input.withUnsafeBytes { input in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count, &output, capacity, &count)
        } } }
        guard result == kCCSuccess else { throw CloudError.message("139 数据加解密失败。") }
        return Data(output.prefix(count))
    }
    static func encrypt(_ data: Data, iv: Data? = nil) throws -> String {
        var random = [UInt8](repeating: 0, count: 16)
        if iv == nil { guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CloudError.message("无法生成 139 请求随机数。") } }
        let iv = iv ?? Data(random)
        return (iv + (try crypt(data, iv: iv, encrypt: true))).base64EncodedString()
    }
    static func decrypt(_ text: String) throws -> Data {
        guard let raw = Data(base64Encoded: text), raw.count >= 32, raw.count <= 2_097_168, raw.count % 16 == 0 else { throw CloudError.message("139 加密响应无效。") }
        let plain = try crypt(Data(raw.dropFirst(16)), iv: Data(raw.prefix(16)), encrypt: false)
        return plain.starts(with: [0x1f, 0x8b]) ? try gunzip(plain) : plain
    }
    private static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CloudError.message("139 解压初始化失败。") }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let status = buffer.withUnsafeMutableBytes { output -> Int32 in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = buffer.count - Int(stream.avail_out)
                guard result.count + count <= 2_097_152 else { throw CloudError.message("139 解压响应超过安全大小。") }
                result.append(contentsOf: buffer.prefix(count))
                if status == Z_STREAM_END { guard stream.avail_in == 0 else { throw CloudError.message("139 压缩响应包含多余数据。") }; return result }
                guard status == Z_OK, count > 0 else { throw CloudError.message("139 压缩响应损坏。") }
            }
        }
    }
    static func cookies(_ text: String) -> [String: String] {
        text.split(separator: ";").reduce(into: [:]) { result, pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]).removingPercentEncoding ?? String(parts[1]) }
        }
    }
    static func identity(cookie: String, fields: [String: String]) throws -> (authorization: String, account: String) {
        let values = cookies(cookie), auth = fields["authorization"] ?? values["authorization"] ?? ""
        guard !auth.contains("\r"), !auth.contains("\n"), auth.count <= 16384,
              let decoded = Data(base64Encoded: auth.hasPrefix("Basic ") ? String(auth.dropFirst(6)) : auth),
              let text = String(data: decoded, encoding: .utf8) else { throw CloudError.message("139 登录态缺少有效 authorization，请完成官网登录或重新导入。") }
        let parts = text.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "pc", parts[1].range(of: "^[0-9]{5,20}$", options: .regularExpression) != nil, !parts[2].isEmpty else { throw CloudError.message("139 账号参数不完整，请重新登录。") }
        if let stored = fields["account"], !stored.isEmpty, stored != parts[1] { throw CloudError.message("139 账号与凭据不一致。") }
        return (auth, String(parts[1]))
    }
}
