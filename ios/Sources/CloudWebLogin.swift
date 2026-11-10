// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

@MainActor
final class WebLoginState: ObservableObject {
    weak var webView: WKWebView?
    @Published var failure: String?
    @Published var saving = false
    @Published var nickname = ""
}

@MainActor
struct CloudWebLogin: View {
    let provider: CloudProvider
    @ObservedObject var vault: CredentialVault
    @StateObject private var state = WebLoginState()
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在平台官方页面完成登录，再点「保存账号」。本次浏览器会话独立，不会覆盖其他账号。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if let failure = state.failure {
                    Text(failure).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                if state.saving { ProgressView("正在验证并保存…").padding() }
                CloudLoginWebView(provider: provider, state: state)
            }
            .navigationTitle("\(provider.rawValue)登录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存账号") { saveTask = Task { await save() } }.disabled(state.saving)
                }
            }
            .onDisappear { saveTask?.cancel(); state.webView?.stopLoading() }
        }
    }

    private func save() async {
        guard !state.saving, let webView = state.webView else { return }
        state.saving = true
        state.failure = nil
        defer { state.saving = false }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                continuation.resume(returning: $0)
            }
        }
        var values: [String: String] = [:]
        for cookie in cookies.sorted(by: { $0.domain.count < $1.domain.count }) {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard domain == provider.cookieDomain || domain.hasSuffix("." + provider.cookieDomain),
                  cookie.expiresDate == nil || cookie.expiresDate! > Date() else { continue }
            values[cookie.name] = cookie.value
        }
        let secret = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        guard !secret.isEmpty else { state.failure = "尚未取得登录 Cookie，请先完成登录。"; return }
        do {
            let client = CloudClient(provider: provider, cookie: secret)
            let nickname = try await client.validateAccount()
            try Task.checkCancellation()
            vault.add(platform: provider.rawValue, remark: nickname, secret: client.cookie)
            if let error = vault.message { state.failure = error }
            else { dismiss() }
        } catch is CancellationError { }
        catch { state.failure = "账号验证失败，请完成登录、检查网络后重试，或使用手动 Cookie。"}
    }
}

@MainActor
struct CloudLoginWebView: UIViewRepresentable {
    let loginURL: URL
    let userAgent: String
    @ObservedObject var state: WebLoginState

    init(provider: CloudProvider, state: WebLoginState) {
        loginURL = provider.loginURL
        userAgent = provider.userAgent
        _state = ObservedObject(wrappedValue: state)
    }

    init(loginURL: URL, userAgent: String, state: WebLoginState) {
        self.loginURL = loginURL
        self.userAgent = userAgent
        _state = ObservedObject(wrappedValue: state)
    }

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
        state.webView = webView
        webView.load(URLRequest(url: loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) { }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let state: WebLoginState
        init(state: WebLoginState) { self.state = state }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.request.url?.scheme?.lowercased() == "https" ||
                  navigationAction.request.url?.absoluteString == "about:blank" else {
                state.failure = "此登录方式需要外部应用或非 HTTPS 页面，请改用网页内的其他登录方式或手动 Cookie。"
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               navigationAction.request.url?.scheme?.lowercased() == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                state.failure = "登录页未能加载，请检查网络或改用手动 Cookie。"
            }
        }
    }
}
