// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum BaiduCookiePolicy {
    static func appliesToPan(_ cookie: HTTPCookie, now: Date = Date()) -> Bool {
        matchesPanScope(cookie) && (cookie.expiresDate.map({ $0 > now }) ?? true)
    }
    static func matchesPanScope(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain == "baidu.com" || domain == "pan.baidu.com" else { return false }
        let path = cookie.path.isEmpty ? "/" : cookie.path
        let target = "/api/gettemplatevariable"
        return target == path || (target.hasPrefix(path) && (path.hasSuffix("/") || target.dropFirst(path.count).hasPrefix("/")))
    }
    static func loginValues(_ cookies: [HTTPCookie], now: Date = Date()) -> [String: String] {
        // Passport-only and unrelated paths must not overwrite the Pan login
        // cookie with a same-named but differently scoped credential.
        let ordered = cookies.filter { appliesToPan($0, now: now) }.sorted {
            if $0.domain.count != $1.domain.count { return $0.domain.count < $1.domain.count }
            return $0.path.count < $1.path.count
        }
        return ordered.reduce(into: [:]) { $0[$1.name] = $1.value }
    }
}
