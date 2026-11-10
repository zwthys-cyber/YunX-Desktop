// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import AVKit
import ImageIO

@MainActor
final class MediaScreenModel: ObservableObject {
    @Published var result: MediaResult?
    @Published var failure: String?
    @Published var notice: String?
    @Published private(set) var busy = false

    func resolve(_ link: MediaLink, cookie: String, part: Int? = nil, quality: Int? = nil, preferDASH: Bool = false) async {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        defer { busy = false }
        do {
            let resolved = try await MediaClient().resolve(link, cookie: cookie, part: part, quality: quality, preferDASH: preferDASH)
            try Task.checkCancellation()
            result = resolved
            notice = resolved.notice
        } catch is CancellationError { }
        catch { failure = error.localizedDescription }
    }

    func clear() { result = nil; failure = nil; notice = nil }

    func download(_ assets: [MediaAsset], store: DownloadStore, assemblies: MediaAssemblyStore) {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        Task { @MainActor in
            defer { busy = false }
            var added = 0
            var hls = 0
            for asset in assets {
                do {
                    if asset.audioURL != nil {
                        guard assemblies.add(asset) else { throw CloudError.message(assemblies.storageError ?? "无法创建合轨任务。") }
                    } else if asset.isHLS { try await NativeEngine.shared.createHLS(asset); hls += 1 }
                    else if !store.add(asset.url, filename: asset.filename, headers: asset.headers, expectedSize: asset.size, expectedMedia: asset.kind == .image ? "image" : "video") {
                        throw CloudError.message(store.storageError ?? "创建下载任务失败。")
                    }
                    added += 1
                } catch { failure = "创建媒体任务失败，请检查引擎、资源或网络。"; break }
            }
            if assets.contains(where: { $0.audioURL != nil }) { notice = "已加入 \(added) 项，分轨任务请到「下载 → 合轨任务」查看。"; return }
            notice = hls > 0 ? "已加入 \(added) 项；HLS 任务请到「下载 → 引擎任务」查看。" : "已加入 \(added) 个文件，请到「下载」查看。"
        }
    }

}

@MainActor
struct MediaScreen: View {
    @EnvironmentObject var library: LinkLibrary
    @EnvironmentObject var assemblies: MediaAssemblyStore
    @ObservedObject var vault: CredentialVault
    @ObservedObject var downloads: DownloadStore
    @StateObject private var model = MediaScreenModel()
    @State private var provider: MediaProvider = .bilibili
    @State private var preferDASH = true
    @State private var accountID: UUID?
    @State private var input = ""
    @State private var loadedLink: MediaLink?
    @State private var loadedCookie = ""
    @State private var preview: MediaPreviewRoute?
    @State private var browserRoute: BrowserMediaRoute?
    @State private var action: Task<Void, Never>?
    @State private var confirmAll = false
    private var accounts: [SavedCredential] { vault.accounts.filter { $0.platform == provider.rawValue } }

    var body: some View {
        NavigationStack {
            List {
                Section("作品解析") {
                    Picker("平台", selection: $provider) {
                        ForEach(MediaProvider.allCases) { Text($0.rawValue).tag($0) }
                    }.disabled(model.busy)
                        .onChange(of: provider) { _, _ in accountID = accounts.first(where: { $0.isPrimary == true })?.id; model.clear(); loadedCookie = "" }
                    if provider == .bilibili {
                        Toggle("登录后优先 DASH 高清合轨", isOn: $preferDASH).disabled(model.busy)
                            .onChange(of: preferDASH) { _, _ in model.clear() }
                    }
                    Picker("账号", selection: $accountID) {
                        Text("游客").tag(Optional<UUID>.none)
                        ForEach(accounts) { Text($0.remark.isEmpty ? "已保存账号" : $0.remark).tag(Optional($0.id)) }
                    }.disabled(model.busy)
                    TextField("粘贴作品链接或分享文案", text: $input, axis: .vertical)
                        .lineLimit(2...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                    LibraryPicker(platform: provider.rawValue) { input = $0 }
                    Button("解析") {
                        do {
                            let link = try MediaLink.parse(input)
                            guard link.provider == provider else {
                                model.failure = "请先切换到\(link.provider.rawValue)。"; return
                            }
                            let cookie = accounts.first(where: { $0.id == accountID })?.secret ?? ""
                            library.record(platform: provider.rawValue, text: link.url.absoluteString)
                            loadedLink = link; loadedCookie = cookie
                            if provider.requiresBrowser {
                                browserRoute = BrowserMediaRoute(link: link, cookie: cookie)
                                return
                            }
                            model.clear()
                            action = Task { await model.resolve(link, cookie: cookie, preferDASH: preferDASH) }
                        } catch { model.failure = error.localizedDescription }
                    }.disabled(model.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("B 站可下载单文件或适配的 DASH 音视频并合轨，画质由平台权限决定。Pixiv 当前支持静态原图。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if model.busy { Section { ProgressView("正在解析…") } }
                if let failure = model.failure { Section("提示") { Text(failure).foregroundStyle(.red) } }
                if let notice = model.notice { Section { Text(notice).foregroundStyle(.green) } }
                if let result = model.result {
                    Section("作品") {
                        Text(result.title).font(.headline)
                        Text(result.author).foregroundStyle(.secondary)
                        Link("打开原作品", destination: result.source)
                        if !result.parts.isEmpty {
                            Menu("分 P：\(result.selectedPart)") {
                                ForEach(result.parts) { part in
                                    Button("P\(part.id) · \(part.title)") { reload(part: part.id, quality: result.actualQuality) }
                                }
                            }.disabled(model.busy)
                            Menu("实际画质：\(result.actualQuality.map(MediaNames.quality) ?? "平台默认")") {
                                ForEach(result.qualities) { quality in
                                    Button(quality.title) { reload(part: result.selectedPart, quality: quality.id) }
                                }
                            }.disabled(model.busy)
                            Text("切换请求失败时保留上次成功结果；下载按钮对应当前显示的分 P 与实际画质。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if result.assets.count > 1 {
                            Button("下载全部 \(result.assets.count) 个文件") { confirmAll = true }.disabled(model.busy)
                            if provider == .bilibili {
                                Text("同一分 P 如有多个片段，会分别下载，当前版本不自动拼接。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("可下载内容") {
                        ForEach(result.assets) { asset in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(asset.filename).lineLimit(2)
                                if asset.audioURL != nil { Text(asset.previewURL == nil ? "当前没有可用的单文件预览，请下载合轨后播放。" : "分轨下载后无损合轨；在线预览使用平台单文件流，画质可能不同。").font(.caption).foregroundStyle(.secondary) }
                                if asset.isHLS { Text("HLS 可在线播放；下载由原生引擎合并为实际 TS/fMP4 容器。").font(.caption).foregroundStyle(.secondary) }
                                HStack {
                                    Text(asset.label).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("预览") { preview = MediaPreviewRoute(asset: asset) }.buttonStyle(.bordered).disabled(asset.audioURL != nil && asset.previewURL == nil)
                                    Button("下载") { model.download([asset], store: downloads, assemblies: assemblies) }
                                        .buttonStyle(.bordered).disabled(model.busy)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
            .navigationTitle("视频与图集")
            .onAppear { if accountID == nil { accountID = accounts.first(where: { $0.isPrimary == true })?.id } }
            .sheet(item: $browserRoute) { route in
                BrowserMediaResolver(route: route) { result in
                    model.result = result; model.failure = nil; model.notice = result.notice
                }
            }
            .sheet(item: $preview) { MediaPreviewScreen(asset: $0.asset) }
            .confirmationDialog("将这些文件加入前台下载任务？", isPresented: $confirmAll, titleVisibility: .visible) {
                Button("加入全部下载") {
                    if let result = model.result { model.download(result.assets, store: downloads, assemblies: assemblies) }
                }
            }
            .onDisappear { action?.cancel() }
        }
    }

    private func reload(part: Int, quality: Int?) {
        guard let loadedLink else { return }
        action = Task { await model.resolve(loadedLink, cookie: loadedCookie, part: part, quality: quality, preferDASH: preferDASH) }
    }
}

struct MediaPreviewRoute: Identifiable {
    let id = UUID()
    let asset: MediaAsset
}

@MainActor
final class MoviePreviewState: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var failure: String?
    private var loader: MovieResourceLoader?
    private var proxy: HLSLoopbackProxy?
    private var generation = UUID()
    private var observation: NSKeyValueObservation?

    func start(_ asset: MediaAsset) async {
        stop()
        let current = generation
        let item: AVPlayerItem
        if asset.isHLS {
            do {
                let proxy = try HLSLoopbackProxy(url: asset.url, headers: asset.headers)
                self.proxy = proxy
                let url = try await proxy.start()
                guard generation == current, !Task.isCancelled else { await proxy.stop(); return }
                item = AVPlayerItem(url: url)
            } catch { if generation == current { failure = "无法启动 HLS 播放，请重新解析或下载。" }; return }
        } else {
            let loader = MovieResourceLoader(url: asset.previewURL ?? asset.url, headers: asset.headers)
            self.loader = loader
            item = AVPlayerItem(asset: loader.asset())
        }
        observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                Task { @MainActor [weak self] in
                    guard self?.generation == current else { return }
                    self?.failure = "暂时无法预览，请重新解析或下载后播放。"
                }
            }
        }
        player = AVPlayer(playerItem: item)
        player?.play()
    }

    func stop() {
        generation = UUID()
        if let proxy { Task { await proxy.stop() } }
        proxy = nil
        observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        loader?.close(); loader = nil
        failure = nil
    }
}

@MainActor
struct MediaPreviewScreen: View {
    let asset: MediaAsset
    @StateObject private var movie = MoviePreviewState()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if asset.kind == .video {
                    VStack {
                        if let player = movie.player { VideoPlayer(player: player) }
                        if let failure = movie.failure { Text(failure).foregroundStyle(.red).padding() }
                    }.task { await movie.start(asset) }.onDisappear { movie.stop() }
                } else { MediaImagePreview(asset: asset) }
            }.navigationTitle(asset.label).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

@MainActor
struct MediaImagePreview: View {
    let asset: MediaAsset
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var scale: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: min(UIScreen.main.bounds.width, 900) * scale)
                        .onTapGesture(count: 2) { scale = scale == 1 ? 2 : 1 }
                }
            } else if let failure { Text(failure).foregroundStyle(.red).padding() }
            else { ProgressView("正在加载预览…") }
        }
        .task(id: asset.id) {
            var request = URLRequest(url: asset.previewURL ?? asset.url)
            for (key, value) in asset.headers { request.setValue(value, forHTTPHeaderField: key) }
            do {
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.httpShouldSetCookies = false
                config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = 30
                let session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (localURL, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: localURL) }
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let bytes = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      bytes <= 32 * 1024 * 1024,
                      let source = CGImageSourceCreateWithURL(localURL as CFURL, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary) else {
                    failure = "原图较大或预览格式不支持，可直接下载文件查看。"; return
                }
                image = UIImage(cgImage: thumbnail)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = "图片预览失败，请检查网络或重新解析。" } }
        }
    }
}
