// SPDX-License-Identifier: AGPL-3.0-only
// Public client parameters ported from desktop XunleiConstants / XunleiWebCredential.
import Foundation
import CryptoKit

enum XunleiProtocol {
    static let webID = "Xqp0kJBXWhwaTpB6"
    static let appID = "Xp6vsxz_7IYVw2BB"
    static let appSecret = "Xp6vsy4tN9toTVdMSpomVdXpRmES"
    static let webAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    static let appAgent = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"
    static let webVersion = "1.93.10"
    static let appVersion = "8.31.0.9726"
    static let webSalts = ["DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig", "T", "a1fUxfjOO1/dW++DpGupRgw9P93L", "aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT", "SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq", "sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6", "ZhJdLgL7MGh2GanboB0yk", "Osf", "v"]
    static let appSalts = ["9uJNVj/wLmdwKrJaVj/omlQ", "Oz64Lp0GigmChHMf/6TNfxx7O9PyopcczMsnf", "Eb+L7Ce+Ej48u", "jKY0", "ASr0zCl6v8W4aidjPK5KHd1Lq3t+vBFf41dqv5+fnOd", "wQlozdg6r1qxh0eRmt3QgNXOvSZO6q/GXK", "gmirk+ciAvIgA/cxUUCema47jr/YToixTT+Q6O", "5IiCoM9B1/788ntB", "P07JH0h6qoM6TSUAK2aL9T5s2QBVeY9JWvalf", "+oK0AN"]
    static func captchaSign(device: String, timestamp: String, web: Bool) -> String {
        var value = (web ? webID + webVersion + "pan.xunlei.com" : appID + appVersion + "com.xunlei.downloadprovider") + device + timestamp
        for salt in (web ? webSalts : appSalts) { value = Insecure.MD5.hash(data: Data((value + salt).utf8)).map { String(format: "%02x", $0) }.joined() }
        return "1." + value
    }
    static func trusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "xunlei.com" || host.hasSuffix(".xunlei.com")
    }
    static func validToken(_ text: String) -> Bool {
        (16...16_384).contains(text.utf8.count) && text.range(of: "^[A-Za-z0-9._~+/=-]+$", options: .regularExpression) != nil
    }
    static func string(_ value: Any?) -> String { (value as? String) ?? (value as? NSNumber)?.stringValue ?? "" }
    static func subject(_ token: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return "" }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return string(json["sub"])
    }
}

struct XunleiWebCredential {
    let access: String
    let fields: [String: String]
    init(raw: String) throws {
        guard raw.utf8.count <= 65_536 else { throw CloudError.message("迅雷网页凭据过大。") }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\""), let unwrapped = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) { text = unwrapped }
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw CloudError.message("请提供完整的迅雷网页凭据 JSON，包含设备标识。") }
        try self.init(object: root)
    }
    init(object: [String: Any]) throws {
        var data = object
        for _ in 0..<2 where data["access_token"] == nil && data["accessToken"] == nil {
            if let nested = [data["credentials"], data["token"], data["data"]].compactMap({ $0 as? [String: Any] }).first { data = nested }
        }
        func first(_ keys: [String]) -> String { keys.map { XunleiProtocol.string(data[$0]) }.first { !$0.isEmpty } ?? "" }
        let access = first(["access_token", "accessToken"])
        let refresh = first(["refresh_token", "refreshToken"])
        let device = first(["device_id", "deviceId"])
        guard XunleiProtocol.validToken(access), refresh.isEmpty || XunleiProtocol.validToken(refresh),
              device.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else { throw CloudError.message("迅雷网页凭据不完整，请在官网完成登录后再读取。") }
        let captcha = first(["captcha_token", "captchaToken"])
        self.access = access
        self.fields = ["refreshToken": refresh, "deviceId": device, "captchaToken": XunleiProtocol.validToken(captcha) ? captcha : "", "captchaExpiresAt": first(["captchaExpiresAt"]),
                       "userId": first(["user_id", "userId", "sub"]), "nickname": first(["nick_name", "nickname", "name", "user_name"]), "authType": "webToken"]
    }
}
