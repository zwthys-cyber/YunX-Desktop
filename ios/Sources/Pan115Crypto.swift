// SPDX-License-Identifier: AGPL-3.0-only
// 115's existing wire protocol, ported from desktop Pan115Crypto.kt.
// This is protocol compatibility, not a general purpose encryption scheme.
import Foundation
import Security

enum Pan115Crypto {
    static let modulus = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    private static let table: [UInt8] = [
        0xf0,0xe5,0x69,0xae,0xbf,0xdc,0xbf,0x8a,0x1a,0x45,0xe8,0xbe,0x7d,0xa6,0x73,0xb8,
        0xde,0x8f,0xe7,0xc4,0x45,0xda,0x86,0xc4,0x9b,0x64,0x8b,0x14,0x6a,0xb4,0xf1,0xaa,
        0x38,0x01,0x35,0x9e,0x26,0x69,0x2c,0x86,0x00,0x6b,0x4f,0xa5,0x36,0x34,0x62,0xa6,
        0x2a,0x96,0x68,0x18,0xf2,0x4a,0xfd,0xbd,0x6b,0x97,0x8f,0x4d,0x8f,0x89,0x13,0xb7,
        0x6c,0x8e,0x93,0xed,0x0e,0x0d,0x48,0x3e,0xd7,0x2f,0x88,0xd8,0xfe,0xfe,0x7e,0x86,
        0x50,0x95,0x4f,0xd1,0xeb,0x83,0x26,0x34,0xdb,0x66,0x7b,0x9c,0x7e,0x9d,0x7a,0x81,
        0x32,0xea,0xb6,0x33,0xde,0x3a,0xa9,0x59,0x34,0x66,0x3b,0xaa,0xba,0x81,0x60,0x48,
        0xb9,0xd5,0x81,0x9c,0xf8,0x6c,0x84,0x77,0xff,0x54,0x78,0x26,0x5f,0xbe,0xe8,0x1e,
        0x36,0x9f,0x34,0x80,0x5c,0x45,0x2c,0x9b,0x76,0xd5,0x1b,0x8f,0xcc,0xc3,0xb8,0xf5]
    private static let long: [UInt8] = [0x78,0x06,0xad,0x4c,0x33,0x86,0x5d,0x18,0x4c,0x01,0x3f,0x46]
    static func newKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudError.message("115 请求随机数生成失败。") }
        return Data(bytes)
    }
    private static func derive(_ seed: [UInt8], size: Int) -> [UInt8] {
        (0..<size).map { (seed[$0 % seed.count] &+ table[size * $0]) ^ table[size * (size - 1 - $0)] }
    }
    private static func xor(_ bytes: inout [UInt8], key: [UInt8]) {
        let offset = bytes.count % 4
        for i in bytes.indices { bytes[i] ^= key[(i < offset ? i : i - offset) % key.count] }
    }
    static func encode(_ text: String, key: Data, modulus: String = Pan115Crypto.modulus) throws -> String {
        guard key.count == 16, text.utf8.count <= 65536 else { throw CloudError.message("115 请求数据长度无效。") }
        var body = Array(text.utf8); xor(&body, key: derive(Array(key), size: 4)); body.reverse(); xor(&body, key: long)
        let plain = Array(key) + body, rsa = try publicKey(modulus)
        var output = Data()
        for offset in stride(from: 0, to: plain.count, by: 117) {
            let size = min(117, plain.count - offset), separator = 128 - size - 1
            var block = [UInt8](repeating: 0xff, count: 128); block[0] = 0; block[1] = 2; block[separator] = 0
            block.replaceSubrange((separator + 1)..<128, with: plain[offset..<(offset + size)])
            output.append(try transform(Data(block), key: rsa))
        }
        return output.base64EncodedString()
    }
    static func decode(_ text: String, key: Data, modulus: String = Pan115Crypto.modulus) throws -> Data {
        guard key.count == 16, let encrypted = Data(base64Encoded: text, options: .ignoreUnknownCharacters), !encrypted.isEmpty, encrypted.count % 128 == 0, encrypted.count <= 131072 else { throw CloudError.message("115 加密响应长度无效。") }
        let rsa = try publicKey(modulus)
        var plain = [UInt8]()
        for offset in stride(from: 0, to: encrypted.count, by: 128) {
            let block = Array(try transform(encrypted.subdata(in: offset..<(offset + 128)), key: rsa))
            guard block.count == 128, block[0] == 0, [1, 2].contains(block[1]), let separator = block.dropFirst(2).firstIndex(of: 0), separator >= 10, separator < 127 else { throw CloudError.message("115 响应填充无效。") }
            plain.append(contentsOf: block[(separator + 1)...])
        }
        guard plain.count > 16 else { throw CloudError.message("115 响应缺少密钥数据。") }
        let salt = Array(plain.prefix(16))
        var body = Array(plain.dropFirst(16)); xor(&body, key: derive(salt, size: 12)); body.reverse(); xor(&body, key: derive(Array(key), size: 4))
        return Data(body)
    }
    private static func publicKey(_ hex: String) throws -> SecKey {
        let chars = Array(hex)
        guard chars.count == 256 else { throw CloudError.message("115 协议公钥无效。") }
        var bytes = [UInt8]()
        for offset in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[offset...offset + 1]), radix: 16) else { throw CloudError.message("115 协议公钥无效。") }; bytes.append(byte)
        }
        // PKCS#1 RSAPublicKey, positive 1024-bit modulus and exponent 65537.
        let der = Data([0x30, 0x81, 0x89, 0x02, 0x81, 0x81, 0x00] + bytes + [0x02, 0x03, 0x01, 0x00, 0x01])
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 1024]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error), SecKeyIsAlgorithmSupported(key, .encrypt, .rsaEncryptionRaw) else { throw CloudError.message("当前系统不支持 115 协议公钥。") }
        return key
    }
    private static func transform(_ block: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let result = SecKeyCreateEncryptedData(key, .rsaEncryptionRaw, block as CFData, &error) as Data?, result.count == 128 else { throw CloudError.message("115 协议数据转换失败。") }
        return result
    }
}
