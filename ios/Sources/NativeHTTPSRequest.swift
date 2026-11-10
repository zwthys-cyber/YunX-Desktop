// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct NativeHTTPSRequest {
    let url: URL
    let filename: String?
    let connections: Int
    let checksum: String?
    let headers: [String: String]
    let labels: [String: String]
    init(text: String, filename: String = "", connections: Int = 4, checksum: String = "", headers: [String: String] = [:], labels: [String: String] = [:]) throws {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil, url.pathExtension.lowercased() != "m3u8" else {
            throw CloudError.message("请输入不含账号密码的 HTTPS 文件直链；HLS 请从媒体解析加入。")
        }
        guard (1...512).contains(connections) else { throw CloudError.message("连接数需在 1–512 之间。") }
        let digest = checksum.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard digest.isEmpty || digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw CloudError.message("预期 SHA-256 需为 64 位十六进制。")
        }
        guard !headers.keys.contains(where: { !["referer", "user-agent", "accept"].contains($0.lowercased()) }) else {
            throw CloudError.message("此原生直链入口不接收账号请求头。")
        }
        self.url = url
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        self.filename = name.isEmpty ? nil : FileNamePolicy.name(name)
        self.connections = connections; self.checksum = digest.isEmpty ? nil : digest; self.headers = headers; self.labels = labels
    }
    func body(folder: URL) throws -> Data {
        var extra: [String: Any] = ["connections": connections, "autoTorrent": false, "autoExtract": false]
        if let checksum { extra["checksum"] = ["algorithm": "sha256", "expected": checksum] }
        var options: [String: Any] = ["path": folder.path, "extra": extra, "skipAutoCategorize": true]
        if let filename { options["name"] = filename }
        return try JSONSerialization.data(withJSONObject: ["req": ["url": url.absoluteString, "labels": labels, "extra": ["method": "GET", "header": headers]], "opts": options])
    }
}
