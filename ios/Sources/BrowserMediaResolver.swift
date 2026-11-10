// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

struct BrowserMediaRoute: Identifiable {
    let id = UUID()
    let link: MediaLink
    let cookie: String
}

enum BrowserMediaPayload {
    static func result(_ object: [String: Any], expected: MediaLink, current: URL) throws -> MediaResult {
        guard object["error"] == nil, let resolved = MediaLink.parseURL(current), resolved.provider == expected.provider,
              !resolved.id.isEmpty, expected.id.isEmpty || expected.id == resolved.id,
              let work = object["workID"] as? String, work == resolved.id,
              let source = object["src"] as? String,
              (expected.provider == .douyin ? ["ssr", "hook"] : ["xhs"]).contains(source) else {
            throw CloudError.message("尚未读取到原作品的完整数据，请完成页面验证并等待作品加载后重试。")
        }
        let title = object["title"] as? String ?? expected.provider.rawValue
        let base = MediaNames.filename(title, fallback: expected.provider.rawValue + "_" + resolved.id)
        let referer = expected.provider == .douyin ? "https://www.douyin.com/" : "https://www.xiaohongshu.com/"
        let headers = ["User-Agent": MediaClient.userAgent, "Referer": referer]
        let images = object["images"] as? [String] ?? []
        let motions = object["motions"] as? [String] ?? []
        guard images.count <= 1000, motions.isEmpty || motions.count == images.count else { throw CloudError.message("作品图集/动图数量不一致。") }
        var assets: [MediaAsset] = []
        if !images.isEmpty {
            for (index, raw) in images.enumerated() {
                guard let url = MediaNames.secureURL(raw), url.user == nil, url.password == nil else { throw CloudError.message("作品存在无效图片，未返回不完整图集。") }
                let ext = ["jpg", "jpeg", "png", "webp", "gif", "heic"].contains(url.pathExtension.lowercased()) ? url.pathExtension.lowercased() : "jpg"
                assets.append(MediaAsset(id: "image-\(index)", url: url, previewURL: nil, filename: base + "_\(index + 1)." + ext, label: "平台图片 \(index + 1)/\(images.count)", size: nil, kind: .image, headers: headers))
                if index < motions.count, !motions[index].isEmpty {
                    guard let motion = MediaNames.secureURL(motions[index]), motion.user == nil, motion.password == nil else { throw CloudError.message("动态照片视频地址无效。") }
                    assets[assets.count - 1].livePhotoVideoURL = motion
                    assets.append(MediaAsset(id: "motion-\(index)", url: motion, previewURL: nil, filename: base + "_\(index + 1)_motion.mp4", label: "动态照片视频部分（未合成）", size: nil, kind: .video, headers: headers))
                }
            }
        } else if let raw = object["video"] as? String, let url = MediaNames.secureURL(raw), url.user == nil, url.password == nil {
            let hls = url.pathExtension.lowercased() == "m3u8"
            assets.append(MediaAsset(id: "video", url: url, previewURL: nil, filename: base + (hls ? ".m3u8" : ".mp4"), label: hls ? "HLS 视频" : "平台单文件视频", size: nil, kind: .video, headers: headers, isHLS: hls))
        }
        guard !assets.isEmpty else { throw CloudError.message("作品未返回可下载媒体。") }
        return MediaResult(title: title, author: object["author"] as? String ?? "", source: current, assets: assets, parts: [], qualities: [], selectedPart: 1, actualQuality: nil)
    }
}

@MainActor
final class BrowserMediaState: ObservableObject {
    weak var view: WKWebView?
    @Published var message: String?
    @Published var busy = false
    var closed = false
}

@MainActor
struct BrowserMediaResolver: View {
    let route: BrowserMediaRoute
    let complete: (MediaResult) -> Void
    @StateObject private var state = BrowserMediaState()
    @State private var reading: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在官方页面完成登录/验证并等待作品加载，再点「读取作品」。本次会话独立；不会自动保存登录凭证。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if let message = state.message { Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                if state.busy { ProgressView().padding() }
                BrowserMediaWebView(route: route, state: state)
            }.navigationTitle(route.link.provider.rawValue + "作品页")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("读取作品") { read() }.disabled(state.busy) }
                    ToolbarItem(placement: .bottomBar) { Button("返回原作品") { state.view?.load(URLRequest(url: route.link.url)) } }
                }
        }.onDisappear { reading?.cancel(); state.closed = true; state.view?.stopLoading() }
    }
    @MainActor private func read() {
        guard !state.busy, let view = state.view, let current = view.url else { return }
        guard BrowserMediaWebView.allowed(current, provider: route.link.provider) else { state.message = "请返回平台原作品页。"; return }
        let name = route.link.provider == .douyin ? "douyin-extract" : "xhs-extract"
        guard let scriptURL = Bundle.main.url(forResource: name, withExtension: "js"), let script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            state.message = "作品读取脚本不可用，请重新安装完整构建。"; return
        }
        state.busy = true; state.message = nil
        view.evaluateJavaScript(script) { value, error in
            guard !state.closed else { state.busy = false; return }
            guard error == nil, let object = value as? [String: Any] else { state.busy = false; state.message = "页面数据尚未就绪，请完成验证后重试。"; return }
            reading = Task { @MainActor in
                defer { state.busy = false }
                do {
                    var result = try BrowserMediaPayload.result(object, expected: route.link, current: current)
                    if route.link.provider == .xhs { result = try await XHSImageResolver().resolve(result) }
                    try Task.checkCancellation()
                    guard !state.closed else { return }
                    complete(result); dismiss()
                } catch { if !state.closed && !Task.isCancelled { state.message = "读取失败，请确认当前是原作品并等待完整数据加载。" } }
            }
        }
    }
}

@MainActor
struct BrowserMediaWebView: UIViewRepresentable {
    let route: BrowserMediaRoute
    @ObservedObject var state: BrowserMediaState
    static func allowed(_ url: URL, provider: MediaProvider) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        let domains = provider == .douyin ? ["douyin.com", "iesdouyin.com"] : ["xiaohongshu.com", "xhslink.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(provider: route.link.provider, state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        _ = NetworkProxy.configure(config.websiteDataStore)
        if route.link.provider == .douyin, let url = Bundle.main.url(forResource: "douyin-hook", withExtension: "js"), let script = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let viewport = "document.addEventListener('DOMContentLoaded',function(){var m=document.querySelector('meta[name=viewport]');if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}m.content='width=1280,user-scalable=yes';});"
        config.userContentController.addUserScript(WKUserScript(source: viewport, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = MediaClient.userAgent
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        state.view = view
        Task { @MainActor in
            let domain = route.link.provider == .douyin ? ".douyin.com" : ".xiaohongshu.com"
            for pair in route.cookie.split(separator: ";") {
                let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let cookie = HTTPCookie(properties: [.domain: domain, .path: "/", .name: String(parts[0]), .value: String(parts[1]), .secure: "TRUE"]) else { continue }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    config.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
                }
            }
            guard !state.closed else { return }
            if let secure = MediaNames.secureURL(route.link.url.absoluteString), Self.allowed(secure, provider: route.link.provider) { view.load(URLRequest(url: secure)) }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { coordinator.state.closed = true; view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let provider: MediaProvider
        let state: BrowserMediaState
        init(provider: MediaProvider, state: BrowserMediaState) { self.provider = provider; self.state = state }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard NetworkProxy.ready else { state.message = "代理设置不可用，请到设置中修复。"; decisionHandler(.cancel); return }
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame == false, url.scheme == "https" { decisionHandler(.allow); return }
            if BrowserMediaWebView.allowed(url, provider: provider) || url.absoluteString == "about:blank" { decisionHandler(.allow) }
            else { state.message = "该跳转需要外部应用或站点，请在当前网页选择其他方式。"; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, BrowserMediaWebView.allowed(url, provider: provider) { webView.load(navigationAction.request) }
            return nil
        }
    }
}
