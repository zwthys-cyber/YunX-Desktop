// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum IOSPackageKind: String {
    case resign, resignShare = "resign-share", trollStore = "trollstore"
    static var current: Self {
        (Bundle.main.object(forInfoDictionaryKey: "YunXInstallationStyle") as? String).flatMap(Self.init(rawValue:)) ?? .resign
    }
    func accepts(_ name: String) -> Bool {
        let pattern: String
        switch self {
        case .resign: pattern = #"\AYunX-iOS-Resign(?:-dev)?\.ipa\z"#
        case .resignShare: pattern = #"\AYunX-iOS-Resign-Share(?:-dev)?\.ipa\z"#
        case .trollStore: pattern = #"\AYunX-iOS17-TrollStore(?:-[A-Za-z0-9._]+)?\.ipa\z"#
        }
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}

struct IOSVersion: Comparable, CustomStringConvertible {
    let major: Int; let minor: Int; let patch: Int
    init?(_ text: String, system: Bool = false) {
        var parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if system && parts.count == 2 { parts.append("0") }
        guard parts.count == 3 else { return nil }
        let numbers = parts.compactMap(Int.init)
        guard numbers.count == 3, zip(parts, numbers).allSatisfy({ entry in entry.0 == String(entry.1) && (0...999999).contains(entry.1) }) else { return nil }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (a: Self, b: Self) -> Bool { [a.major, a.minor, a.patch].lexicographicallyPrecedes([b.major, b.minor, b.patch]) }
    static var current: Self { Self(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? Self("0.3.0")! }
    static var system: Self { let value = ProcessInfo.processInfo.operatingSystemVersion; return Self("\(value.majorVersion).\(value.minorVersion).\(value.patchVersion)")! }
}
struct IOSRelease: Decodable {
    struct Asset: Decodable {
        let name: String; let browser_download_url: String; let size: Int64
        let state: String?; let digest: String?
    }
    let tag_name: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}
struct IOSUpdate: Identifiable {
    static let repository = "zwthys-cyber/YunX-Desktop"
    let version: IOSVersion
    let minimumSystem: IOSVersion
    let url: URL
    let sha256: String
    let filename: String
    let notes: String
    let size: Int64
    var id: String { version.description }
    var page: URL { URL(string: "https://github.com/" + Self.repository + "/releases/tag/ios-v" + version.description)! }
    static func select(_ releases: [IOSRelease], current: IOSVersion, system: IOSVersion, package: IOSPackageKind = .current) throws -> Self? {
        let candidates = releases.compactMap { release -> (IOSVersion, IOSRelease)? in
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("ios-v"), let version = IOSVersion(String(release.tag_name.dropFirst(5))), version > current else { return nil }
            return (version, release)
        }.sorted { $0.0 > $1.0 }
        guard let (version, release) = candidates.first else { return nil }
        let assets = release.assets.filter { package.accepts($0.name) && $0.state == "uploaded" }
        guard assets.count == 1, let asset = assets.first, asset.size > 0, asset.size <= 512 * 1024 * 1024,
              let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil, url.path == "/" + repository + "/releases/download/" + release.tag_name + "/" + asset.name else { throw CloudError.message("最新 iOS 发布尚未提供唯一、完整的官方安装包，请查看发布页。") }
        guard let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:"), digest.dropFirst(7).range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw CloudError.message("安装包缺少有效 SHA-256，未提供自动下载。") }
        let notes = String((release.body ?? "").prefix(20000))
        let marker = try NSRegularExpression(pattern: #"<!--\s*yunx-ios-min-os:\s*([^\s>]+)\s*-->"#)
        let matches = marker.matches(in: notes, range: NSRange(notes.startIndex..., in: notes))
        guard matches.count <= 1, !notes.contains("yunx-ios-min-os:") || !matches.isEmpty else { throw CloudError.message("iOS 发布的系统版本声明无效。") }
        let required = matches.first.flatMap { Range($0.range(at: 1), in: notes) }.map { String(notes[$0]) } ?? "17.0"
        guard let minimum = IOSVersion(required, system: true), minimum <= system else { throw CloudError.message("该 iOS 更新要求更高的系统版本，当前设备不适用。") }
        return Self(version: version, minimumSystem: minimum, url: url, sha256: String(digest.dropFirst(7)), filename: asset.name, notes: notes, size: asset.size)
    }
}

final class IOSUpdateClient {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 15
            self.session = NetworkProxy.session(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }
    func fetch() async throws -> [IOSRelease] {
        var result: [IOSRelease] = []
        for page in 1...3 {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/" + IOSUpdate.repository + "/releases?per_page=100&page=\(page)")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept"); request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version"); request.setValue("YunX-iOS", forHTTPHeaderField: "User-Agent")
            do {
                let (bytes, response) = try await session.bytes(for: request); defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw CloudError.message("更新检查暂不可用，请稍后重试或查看发布页。") }
                var data = Data()
                for try await byte in bytes { guard data.count < 4_194_304 else { throw CloudError.message("发布信息超过安全大小。") }; data.append(byte) }
                let releases = try JSONDecoder().decode([IOSRelease].self, from: data)
                guard releases.count <= 100 else { throw CloudError.message("发布分页数据无效。") }; result += releases
                if releases.count < 100 { break }
            } catch let error as CloudError { throw error }
            catch { if Task.isCancelled { throw CancellationError() }; throw CloudError.message("更新检查失败，请检查网络后重试。") }
        }
        return result
    }
}

@MainActor
final class IOSUpdateStore: ObservableObject {
    static let shared = IOSUpdateStore()
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "automaticIOSUpdates") } }
    @Published var prompt: IOSUpdate?
    @Published private(set) var latest: IOSUpdate?
    @Published private(set) var message: String?
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    private let client: IOSUpdateClient
    private let defaults: UserDefaults
    private let package: IOSPackageKind
    init(client: IOSUpdateClient = IOSUpdateClient(), defaults: UserDefaults = .standard, package: IOSPackageKind = .current) {
        self.client = client; self.defaults = defaults; self.package = package; automatic = defaults.bool(forKey: "automaticIOSUpdates"); lastChecked = defaults.object(forKey: "lastIOSUpdateCheck") as? Date
    }
    func check(automatic: Bool = false) async {
        guard !checking else { return }
        if automatic { guard self.automatic, lastChecked.map({ Date().timeIntervalSince($0) >= 21600 }) ?? true else { return } }
        checking = true; latest = nil; message = nil; defer { checking = false }
        do {
            let releases = try await client.fetch()
            try Task.checkCancellation()
            lastChecked = Date(); defaults.set(lastChecked, forKey: "lastIOSUpdateCheck")
            latest = try IOSUpdate.select(releases, current: .current, system: .system, package: package)
            if automatic {
                if let latest, defaults.string(forKey: "ignoredIOSUpdate") != latest.id { prompt = latest }
            } else { message = latest == nil ? "没有发现比当前版本更新的正式 iOS 安装包。" : "已找到可校验的 iOS 更新。" }
        } catch { if !automatic && !Task.isCancelled { message = error is CloudError ? error.localizedDescription : "更新检查失败，请稍后重试。" } }
    }
    func ignore() { if let latest { defaults.set(latest.id, forKey: "ignoredIOSUpdate") }; prompt = nil }
}

@MainActor
struct IOSUpdatesScreen: View {
    @ObservedObject var store: IOSUpdateStore
    var modal = false
    @State private var adding = false
    @State private var queuedVersion: String?
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                LabeledContent("当前版本", value: IOSVersion.current.description)
                Toggle("启动时自动检查 iOS 更新", isOn: $store.automatic)
                Button("检查更新") { Task { await store.check() } }.disabled(store.checking)
                if store.checking { ProgressView() }
                if let date = store.lastChecked { Text("上次检查：" + date.formatted(date: .abbreviated, time: .shortened)).font(.footnote) }
                if let text = store.message { Text(text).font(.footnote) }
                Link("查看发布列表", destination: URL(string: "https://github.com/" + IOSUpdate.repository + "/releases")!)
            }
            if let update = store.latest {
                Section("iOS \(update.version.description)") {
                    Text(ByteCountFormatter.string(fromByteCount: update.size, countStyle: .file))
                    Text(update.notes).textSelection(.enabled)
                    Link("打开此版本发布页", destination: update.page)
                    Button(queuedVersion == update.id ? "已加入校验下载队列" : "下载并校验 IPA") { Task { await download(update) } }.disabled(adding || queuedVersion == update.id)
                    NavigationLink("查看下载任务") { P2PScreen() }
                    Button("忽略此版本的自动提醒") { store.ignore() }
                }
            }
            if let message { Text(message).font(.footnote) }
            Text("自动检查默认关闭，启用后在启动时最多每 6 小时检查一次。仅识别与当前安装方式一致的 iOS 正式发布和官方 SHA-256；校验后导出 IPA。普通签名版本需交给签名软件或服务重新签名，TrollStore 版本使用其对应安装方式。")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("iOS 更新").toolbar { if modal { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } } }
    }
    private func download(_ update: IOSUpdate) async {
        guard !adding, queuedVersion != update.id else { return }; adding = true; defer { adding = false }
        do {
            let request = try NativeHTTPSRequest(text: update.url.absoluteString, filename: update.filename, checksum: update.sha256, labels: ["yunxUpdate": update.id])
            _ = try await NativeEngine.shared.createHTTPS(request)
            queuedVersion = update.id; message = "已加入原生引擎队列；完成校验后可导出 IPA 安装。"
        } catch { message = "安装包无法加入队列，请检查网络或稍后重试。" }
    }
}
