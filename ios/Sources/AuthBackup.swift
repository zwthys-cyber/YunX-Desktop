// SPDX-License-Identifier: AGPL-3.0-only
// Wire format matches desktop AuthCrypto / AuthBackupManager.
import Foundation
import CryptoKit
import CommonCrypto
import Security

enum AuthBackup {
    static let maximumBytes = 8 * 1024 * 1024
    private static let names = ["quark": "夸克", "uc": "UC", "xunlei": "迅雷", "baidu": "百度", "c139": "139", "pan123": "123", "pan115": "115", "guangya": "光鸭", "lanzou": "蓝奏云", "ilanzou": "蓝奏优享", "video:BILIBILI": "哔哩哔哩", "video:PIXIV": "Pixiv", "video:DOUYIN": "抖音", "video:KUAISHOU": "快手", "video:WEIBO": "微博", "video:XHS": "小红书", "video:ACFUN": "AcFun"]
    private static func derive(_ password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let passwordBytes = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.bindMemory(to: Int8.self).baseAddress, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &output, 32)
            }
        }
        guard status == kCCSuccess else { throw CloudError.message("无法派生备份密钥。") }
        return SymmetricKey(data: output)
    }
    static func encrypt(_ plain: Data, password: String) throws -> Data {
        guard password.utf16.count >= 8 else { throw CloudError.message("备份口令至少 8 位。") }
        guard plain.count <= maximumBytes / 2 else { throw CloudError.message("备份内容过大。") }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw CloudError.message("无法生成备份随机盐。")
        }
        let saltData = Data(salt)
        let key = try derive(password, salt: saltData, rounds: 210_000)
        let sealed = try AES.GCM.seal(plain, using: key)
        guard let combined = sealed.combined else { throw CloudError.message("备份加密失败。") }
        return (Data("YUNX_AUTH_V2".utf8) + saltData + combined).base64EncodedData()
    }
    static func decrypt(_ encrypted: Data, password: String) throws -> Data {
        guard encrypted.count <= maximumBytes, let text = String(data: encrypted, encoding: .utf8),
              let payload = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CloudError.message("不是有效的云析加密备份。")
        }
        let header = Data("YUNX_AUTH_V2".utf8)
        let rounds: UInt32
        if payload.starts(with: header) { rounds = 210_000 }
        else if payload.starts(with: Data("YUNX_AUTH_V1".utf8)) { rounds = 10_000 }
        else { throw CloudError.message("不支持的备份格式。") }
        guard payload.count >= header.count + 16 + 12 + 16 else { throw CloudError.message("备份文件不完整。") }
        let salt = payload.subdata(in: header.count..<(header.count + 16))
        let combined = payload.subdata(in: (header.count + 16)..<payload.count)
        do {
            let key = try derive(password, salt: salt, rounds: rounds)
            return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        } catch { throw CloudError.message("备份口令错误或文件已损坏。") }
    }
    static func encode(_ credentials: [SavedCredential], password: String) throws -> Data {
        let reverse = Dictionary(uniqueKeysWithValues: names.map { ($0.value, $0.key) })
        var accounts: [[String: Any]] = []
        var githubToken: String?
        for account in credentials {
            if account.platform == "GitHub" {
                // Keep the legacy scalar for desktop readers; iOS also preserves multiple Tokens below.
                if githubToken == nil || account.isPrimary == true { githubToken = account.secret }
            }
            var record: [String: Any] = account.backupFields ?? [:]
            record["platform"] = reverse[account.platform] ?? (account.platform == "GitHub" ? "github" : "ios:" + account.platform)
            record["id"] = account.id.uuidString
            record["remark"] = account.remark
            record["nickname"] = account.remark
            record["isPrimary"] = account.isPrimary ?? false
            record["updatedAt"] = Int64(Date().timeIntervalSince1970 * 1000)
            let field: String
            switch account.platform {
            case "123", "迅雷", "光鸭": field = "accessToken"
            case "蓝奏优享": field = "appToken"
            case "GitHub": field = "token"
            default: field = "cookie"
            }
            record[field] = account.secret
            accounts.append(record)
        }
        var root: [String: Any] = ["app": "yunx_auth_backup", "version": 1, "exportedAt": Int64(Date().timeIntervalSince1970 * 1000), "accounts": accounts]
        if let githubToken { root["githubToken"] = githubToken }
        return try encrypt(JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]), password: password)
    }
    static func decode(_ encrypted: Data, password: String) throws -> [SavedCredential] {
        let plain = try decrypt(encrypted, password: password)
        guard let root = try JSONSerialization.jsonObject(with: plain) as? [String: Any],
              root["app"] as? String == "yunx_auth_backup", (root["version"] as? Int) == 1,
              let records = root["accounts"] as? [[String: Any]], records.count <= 1000 else {
            throw CloudError.message("备份账号结构无效或版本不受支持。")
        }
        var accounts: [SavedCredential] = []
        for record in records {
            guard let code = record["platform"] as? String else { throw CloudError.message("备份中存在无平台信息的账号。") }
            let name = names[code] ?? (code == "github" ? "GitHub" : (code.hasPrefix("ios:") ? String(code.dropFirst(4)) : ""))
            guard !name.isEmpty else { throw CloudError.message("备份包含不支持的平台：" + code) }
            let field: String
            switch code {
            case "pan123", "xunlei", "guangya": field = "accessToken"
            case "ilanzou": field = "appToken"
            case "github": field = "token"
            default: field = "cookie"
            }
            guard let secret = record[field] as? String, !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CloudError.message("备份中存在缺失凭证的账号，未导入任何内容。")
            }
            var account = SavedCredential(platform: name, remark: record["remark"] as? String ?? record["nickname"] as? String ?? "", secret: secret)
            if let raw = record["id"] as? String, let id = UUID(uuidString: raw) { account.id = id }
            account.isPrimary = record["isPrimary"] as? Bool
            account.backupFields = record.compactMapValues { $0 as? String }
            accounts.append(account)
        }
        if !accounts.contains(where: { $0.platform == "GitHub" }), let token = root["githubToken"] as? String, !token.isEmpty {
            accounts.append(SavedCredential(platform: "GitHub", remark: "桌面版 GitHub", secret: token))
        }
        return accounts
    }
}
