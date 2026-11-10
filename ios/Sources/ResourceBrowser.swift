// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

struct BrowserResource: Identifiable {
    enum Kind: String, CaseIterable { case image, video, audio, document, archive, program, font, other
        var title: String { switch self { case .image: return "图片"; case .video: return "视频"; case .audio: return "音频"; case .document: return "文档"; case .archive: return "压缩包/种子"; case .program: return "安装包"; case .font: return "字体"; case .other: return "其他文件" } }
    }
    let url: URL
    let kind: Kind
    let filename: String
    let referer: URL
    let size: Int64?
    var id: String { url.absoluteString }
    var isHLS: Bool { kind == .video && url.pathExtension.lowercased() == "m3u8" }
    var headers: [String: String] {
        var origin = URLComponents(url: referer, resolvingAgainstBaseURL: false)
        origin?.path = "/"; origin?.query = nil; origin?.fragment = nil; origin?.user = nil; origin?.password = nil
        return ["User-Agent": MediaClient.userAgent, "Referer": origin?.url?.absoluteString ?? ""]
    }
    static func safeURL(_ text: String) -> URL? {
        guard text.utf8.count <= 16384, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }; return url
    }
    static func samePage(_ first: URL, _ second: URL) -> Bool {
        var a = URLComponents(url: first, resolvingAgainstBaseURL: false), b = URLComponents(url: second, resolvingAgainstBaseURL: false)
        a?.fragment = nil; b?.fragment = nil; return a?.url == b?.url
    }
    static func parse(_ object: [String: Any], current: URL) throws -> [BrowserResource] {
        guard safeURL(current.absoluteString) != nil, let page = object["page"] as? String, let url = safeURL(page), samePage(url, current), let rows = object["resources"] as? [[String: Any]], rows.count <= 200 else { throw CloudError.message("页面已变化或资源列表无效，请重新读取。") }
        var seen = Set<URL>()
        return try rows.compactMap { row in
            guard let raw = row["url"] as? String, let url = safeURL(raw), let rawKind = row["kind"] as? String, let kind = Kind(rawValue: rawKind) else { throw CloudError.message("页面资源包含不支持的地址或分类。") }
            guard seen.insert(url).inserted else { return nil }
            return BrowserResource(url: url, kind: kind, filename: FileNamePolicy.name(url.lastPathComponent.isEmpty ? "resource" : url.lastPathComponent), referer: current, size: nil)
        }
    }
}

@MainActor
final class ResourceBrowserState: ObservableObject {
    weak var view: WKWebView?
    @Published var message: String?
    @Published var busy = false
    @Published var resources: [BrowserResource] = []
    @Published var candidate: BrowserResource?
    @Published var currentHost = ""
    var closed = false
}

@MainActor
struct ResourceBrowserScreen: View {
    @ObservedObject var downloads: DownloadStore
    @StateObject private var state = ResourceBrowserState()
    @State private var address = ""
    @State private var showResources = false
    @State private var reading: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("HTTPS 网页地址", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).onSubmit(open)
                Button("访问", action: open)
            }.padding()
            HStack {
                Button("后退") { state.view?.goBack() }
                Button("前进") { state.view?.goForward() }
                Button("刷新") { state.view?.reload() }
                Spacer()
                Button("读取资源") { reading = Task { await read() } }.disabled(state.busy || state.view?.url == nil)
            }.padding(.horizontal).padding(.bottom, 8)
            if state.busy { ProgressView().padding(4) }
            if let message = state.message { Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            ResourceWebView(state: state)
        }.navigationTitle(state.currentHost.isEmpty ? "资源浏览器" : state.currentHost).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showResources) { ResourceListScreen(state: state, downloads: downloads) }
            .confirmationDialog("下载此文件？", isPresented: Binding(get: { state.candidate != nil }, set: { if !$0 { state.candidate = nil } }), titleVisibility: .visible, presenting: state.candidate) { resource in
                Button("加入下载队列") { Task { await enqueue(resource) }; state.candidate = nil }
                Button("取消", role: .cancel) { state.candidate = nil }
            } message: { resource in Text(resource.filename + "\n" + (resource.url.host ?? "")) }
            .onDisappear { reading?.cancel(); state.view?.stopLoading(); state.closed = true }
            .onAppear { state.closed = false }
    }
    private func open() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = BrowserResource.safeURL(value.contains("://") ? value : "https://" + value) else { state.message = "请输入不含账号密码的 HTTPS 网页地址。"; return }
        state.message = nil; state.resources = []; state.view?.load(URLRequest(url: url))
    }
    private func read() async {
        guard !state.busy, let view = state.view, let current = view.url else { return }
        state.busy = true; state.message = nil
        defer { state.busy = false }
        do {
            let source = try ResourceBrowserScript.script()
            let result = try await view.evaluateJavaScript(source)
            try Task.checkCancellation()
            guard !state.closed, let after = view.url, BrowserResource.samePage(current, after), let object = result as? [String: Any] else { throw CloudError.message("页面已变化，请重新读取。") }
            state.resources = try BrowserResource.parse(object, current: current)
            let omitted = (object["omitted"] as? NSNumber)?.intValue ?? 0
            state.message = omitted > 0 ? "最多显示 200 项，另有 \(omitted) 项未列出。" : "已读取 \(state.resources.count) 项资源。"
            showResources = true
        } catch is CancellationError { }
        catch { state.message = error is CloudError ? error.localizedDescription : "资源读取失败，请等待页面完成加载后重试。" }
    }
    private func enqueue(_ resource: BrowserResource) async {
        do {
            if resource.isHLS {
                let asset = MediaAsset(id: resource.id, url: resource.url, previewURL: nil, filename: resource.filename, label: resource.kind.title, size: resource.size, kind: .video, headers: resource.headers, isHLS: true)
                try await NativeEngine.shared.createHLS(asset)
            } else { guard downloads.add(resource.url, filename: resource.filename, headers: resource.headers, expectedSize: resource.size) else { throw CloudError.message(downloads.storageError ?? "下载无法加入队列。") } }
            state.message = "已加入下载队列。"
        } catch { state.message = error is CloudError ? error.localizedDescription : "下载无法加入队列，请重试。" }
    }
}

// Shared by the real browser and JavaScriptCore fixture tests.
enum ResourceBrowserScript {
    static func script() throws -> String {
        guard let url = Bundle.main.url(forResource: "browser-resources", withExtension: "js") else { throw CloudError.message("浏览器资源脚本缺失。") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

@MainActor
private struct ResourceListScreen: View {
    @ObservedObject var state: ResourceBrowserState
    @ObservedObject var downloads: DownloadStore
    @State private var filter: BrowserResource.Kind?
    @State private var message: String?
    @State private var preview: MediaPreviewRoute?
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("读取当前页面已加载的 DOM 和资源记录；不读取 Cookie。blob、DRM、未加载资源及网页隐藏的请求不在此列表。需要账号鉴权的资源可能无法下载，请使用对应平台解析入口。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("分类", selection: $filter) {
                        Text("全部").tag(Optional<BrowserResource.Kind>.none)
                        ForEach(BrowserResource.Kind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    if let message { Text(message).font(.footnote) }
                }
                ForEach(state.resources.filter { filter == nil || $0.kind == filter }) { resource in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(resource.filename).lineLimit(2)
                        Text(resource.kind.title + " · " + (resource.url.host ?? "")).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if [.image, .video, .audio].contains(resource.kind) {
                                Button("预览") { preview = MediaPreviewRoute(asset: asset(resource)) }.buttonStyle(.bordered)
                            }
                            Button("下载") { Task { await add(resource) } }.buttonStyle(.bordered).disabled(adding)
                            ShareLink(item: resource.url) { Text("分享链接") }.buttonStyle(.bordered)
                        }
                    }
                }
                if state.resources.isEmpty { ContentUnavailableView("未发现可下载资源", systemImage: "doc.text.magnifyingglass") }
            }.navigationTitle("网页资源").toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(item: $preview) { MediaPreviewScreen(asset: $0.asset) }
        }
    }
    private func asset(_ resource: BrowserResource) -> MediaAsset {
        MediaAsset(id: resource.id, url: resource.url, previewURL: nil, filename: resource.filename, label: resource.kind.title, size: resource.size, kind: resource.kind == .image ? .image : .video, headers: resource.headers, isHLS: resource.isHLS)
    }
    private func add(_ resource: BrowserResource) async {
        guard !adding else { return }; adding = true; defer { adding = false }
        do {
            if resource.isHLS { try await NativeEngine.shared.createHLS(asset(resource)) }
            else { guard downloads.add(resource.url, filename: resource.filename, headers: resource.headers, expectedSize: resource.size, expectedMedia: resource.kind == .image && resource.url.pathExtension.lowercased() != "svg" ? "image" : (resource.kind == .video ? "video" : nil)) else { throw CloudError.message(downloads.storageError ?? "下载无法加入队列。") } }
            message = "已加入下载队列。"
        } catch { message = error is CloudError ? error.localizedDescription : "下载无法加入队列，请重试。" }
    }
}

@MainActor
private struct ResourceWebView: UIViewRepresentable {
    @ObservedObject var state: ResourceBrowserState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.customUserAgent = MediaClient.userAgent; view.allowsBackForwardNavigationGestures = true; state.view = view; return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: ResourceBrowserState
        init(state: ResourceBrowserState) { self.state = state }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, BrowserResource.safeURL(url.absoluteString) != nil || url.absoluteString == "about:blank" else { state.message = "此浏览器只打开 HTTPS 页面。"; decisionHandler(.cancel); return }
            decisionHandler(.allow)
        }
        func webView(_ view: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let response = navigationResponse.response
            let attachment = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
            if navigationResponse.isForMainFrame, attachment || !navigationResponse.canShowMIMEType, let raw = response.url?.absoluteString, let url = BrowserResource.safeURL(raw) {
                state.candidate = BrowserResource(url: url, kind: url.pathExtension.lowercased() == "m3u8" ? .video : .other, filename: FileNamePolicy.name(response.suggestedFilename ?? url.lastPathComponent), referer: view.url ?? url, size: response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { state.currentHost = view.url?.host ?? "" }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { if (error as NSError).code != NSURLErrorCancelled { state.message = "网页加载失败，请检查地址或网络。" } }
        func webView(_ view: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil, let raw = action.request.url?.absoluteString, BrowserResource.safeURL(raw) != nil { view.load(action.request) }; return nil
        }
    }
}
