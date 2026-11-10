// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Network
import WebKit
import Security
import CFNetwork

enum NetworkProxyError: LocalizedError {
    case invalid, unavailable, pac
    var errorDescription: String? {
        switch self {
        case .invalid: return "代理设置无效，请检查协议、主机、端口和认证信息。"
        case .unavailable: return "代理设置无法读取或保存，请解锁设备后重试。"
        case .pac: return "原生下载引擎暂不解析系统 PAC，请使用手动代理。"
        }
    }
}
struct NetworkProxyProfile: Codable, Equatable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case system, direct, manual
        var title: String { switch self { case .system: return "跟随系统"; case .direct: return "原生请求直连"; case .manual: return "手动代理" } }
    }
    enum Scheme: String, Codable, CaseIterable, Sendable { case http, https, socks5 }
    var schema = 1
    var mode: Mode = .system
    var scheme: Scheme = .http
    var host = ""
    var port: UInt16 = 8080
    var username = ""
    var password = ""
    func validated() throws -> Self {
        guard schema == 1 else { throw NetworkProxyError.invalid }
        guard mode == .manual else { return self }
        var result = self
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.host.hasPrefix("["), result.host.hasSuffix("]") { result.host = String(result.host.dropFirst().dropLast()) }
        let dns = result.host.hasSuffix(".") ? String(result.host.dropLast()) : result.host
        let labels = dns.split(separator: ".", omittingEmptySubsequences: false)
        let validDNS = !labels.isEmpty && labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
        }
        guard !result.host.isEmpty, result.host.utf8.count <= 253, port > 0, validDNS || IPv6Address(result.host) != nil,
              username.utf8.count <= 512, password.utf8.count <= 4096, !username.contains(":"),
              !(username.isEmpty && !password.isEmpty), !(username + password).unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              scheme != .socks5 || (username.utf8.count <= 255 && password.utf8.count <= 255) else { throw NetworkProxyError.invalid }
        return result
    }
    func configuration() throws -> ProxyConfiguration {
        let profile = try validated()
        guard mode == .manual, let endpointPort = NWEndpoint.Port(rawValue: profile.port) else { throw NetworkProxyError.invalid }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(profile.host), port: endpointPort)
        var proxy: ProxyConfiguration
        if scheme == .socks5 { proxy = ProxyConfiguration(socksv5Proxy: endpoint) }
        else { proxy = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: scheme == .https ? NWProtocolTLS.Options() : nil) }
        proxy.allowFailover = false
        proxy.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        if !profile.username.isEmpty { proxy.applyCredential(username: profile.username, password: profile.password) }
        return proxy
    }
    func runtime(for url: URL) throws -> [String: Any] {
        switch mode {
        case .direct: return ["direct": true]
        case .manual:
            let profile = try validated()
            return ["scheme": profile.scheme.rawValue, "host": profile.host, "port": Int(profile.port), "username": profile.username, "password": profile.password]
        case .system:
            guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return ["direct": true] }
            let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]] ?? []
            guard let proxy = proxies.first else { return ["direct": true] }
            let type = proxy[kCFProxyTypeKey as String] as? String ?? ""
            if type == kCFProxyTypeNone as String { return ["direct": true] }
            if type == kCFProxyTypeAutoConfigurationURL as String || type == kCFProxyTypeAutoConfigurationJavaScript as String { throw NetworkProxyError.pac }
            guard [kCFProxyTypeHTTP as String, kCFProxyTypeHTTPS as String, kCFProxyTypeSOCKS as String].contains(type),
                  let host = proxy[kCFProxyHostNameKey as String] as? String, let port = (proxy[kCFProxyPortNumberKey as String] as? NSNumber)?.intValue, (1...65535).contains(port) else { throw NetworkProxyError.invalid }
            // Legacy system HTTPS entries describe CONNECT to an HTTP proxy.
            var profile = NetworkProxyProfile(); profile.mode = .manual; profile.scheme = type == kCFProxyTypeSOCKS as String ? .socks5 : .http
            profile.host = host; profile.port = UInt16(port); profile.username = proxy[kCFProxyUsernameKey as String] as? String ?? ""; profile.password = proxy[kCFProxyPasswordKey as String] as? String ?? ""
            return try profile.runtime(for: url)
        }
    }
}

enum NetworkProxyKeychain {
    static let service = "io.github.zwthys.yunx.network-proxy.v1"
    private static func query(_ service: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "profile"] }
    static func read(service: String = NetworkProxyKeychain.service) throws -> NetworkProxyProfile {
        var query = Self.query(service); query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return NetworkProxyProfile() }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 32768 else { throw NetworkProxyError.unavailable }
        do { return try JSONDecoder().decode(NetworkProxyProfile.self, from: data).validated() }
        catch { throw NetworkProxyError.invalid }
    }
    static func save(_ profile: NetworkProxyProfile, service: String = NetworkProxyKeychain.service) throws {
        let data = try JSONEncoder().encode(profile.validated())
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let query = Self.query(service)
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, value in value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw NetworkProxyError.unavailable }
        } else if status != errSecSuccess { throw NetworkProxyError.unavailable }
    }
    static func remove(service: String = NetworkProxyKeychain.service) { SecItemDelete(Self.query(service) as CFDictionary) }
}

private final class ProxyProfileCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<NetworkProxyProfile, Error>?
    func read() -> Result<NetworkProxyProfile, Error> {
        lock.lock(); defer { lock.unlock() }
        if let value { return value }
        let result = Result { try NetworkProxyKeychain.read() }; value = result; return result
    }
    func save(_ profile: NetworkProxyProfile) throws {
        lock.lock(); defer { lock.unlock() }
        let validated = try profile.validated(); try NetworkProxyKeychain.save(validated); value = .success(validated)
    }
    func reload() -> Result<NetworkProxyProfile, Error> {
        lock.lock(); defer { lock.unlock() }
        let result = Result { try NetworkProxyKeychain.read() }; value = result; return result
    }
}
private final class ProxyBlockedProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: NetworkProxyError.unavailable) }
    override func stopLoading() { }
}
enum NetworkProxy {
    private static let cache = ProxyProfileCache()
    static func current() throws -> NetworkProxyProfile { try cache.read().get() }
    static func save(_ profile: NetworkProxyProfile) throws { try cache.save(profile) }
    static func reload() throws -> NetworkProxyProfile { try cache.reload().get() }
    static var ready: Bool { (try? current()) != nil }
    static var supportsBackground: Bool { (try? current().mode) == .system }
    static func configure(_ config: URLSessionConfiguration, profile: NetworkProxyProfile) throws {
        let profile = try profile.validated()
        config.proxyConfigurations = []
        config.connectionProxyDictionary = nil
        switch profile.mode {
        case .system: break
        case .direct: config.connectionProxyDictionary = [:]
        case .manual: config.proxyConfigurations = [try profile.configuration()]
        }
    }
    static func session(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, delegateQueue: OperationQueue?) -> URLSession {
        do { try configure(configuration, profile: current()) }
        catch { configuration.protocolClasses = [ProxyBlockedProtocol.self] }
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    }
    @MainActor static func configure(_ store: WKWebsiteDataStore) -> Bool {
        do {
            let profile = try current()
            store.proxyConfigurations = profile.mode == .manual ? [try profile.configuration()] : []
            return true
        } catch { return false }
    }
    static func runtimeJSON(for rawURL: String, fixed: NetworkProxyProfile? = nil) -> String {
        do {
            guard let url = URL(string: rawURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NetworkProxyError.invalid }
            let profile = try fixed ?? current()
            return String(decoding: try JSONSerialization.data(withJSONObject: profile.runtime(for: url)), as: UTF8.self)
        } catch { return #"{"error":true}"# }
    }
}
