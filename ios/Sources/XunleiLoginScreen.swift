// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

@MainActor
struct XunleiLoginScreen: View {
    @ObservedObject var vault: CredentialVault
    @StateObject private var state = WebLoginState()
    @State private var imported = ""
    @State private var action: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在迅雷官网完成密码、短信或扫码登录，再读取并验证账号。此会话独立，凭据只保存到本应用钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if let failure = state.failure { Text(failure).font(.caption).foregroundStyle(.red).padding(.horizontal) }
                if state.saving { ProgressView("正在验证网盘访问…") }
                DisclosureGroup("手动导入完整网页凭据") {
                    SecureField("凭据 JSON（需设备标识）", text: $imported).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("验证并保存导入") { action = Task { await save(imported: true) } }.disabled(state.saving || imported.isEmpty)
                }.padding(.horizontal)
                XunleiAuthWebView(state: state)
            }.navigationTitle("迅雷官网登录")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { action?.cancel(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("读取并验证") { action = Task { await save(imported: false) } }.disabled(state.saving) }
                }
        }.onDisappear { action?.cancel(); state.webView?.stopLoading(); imported = "" }
    }
    private func save(imported: Bool) async {
        guard !state.saving else { return }
        state.saving = true; state.failure = nil
        defer { state.saving = false }
        do {
            let credential: XunleiWebCredential
            if imported { credential = try XunleiWebCredential(raw: self.imported) }
            else {
                guard let view = state.webView, let url = view.url, XunleiProtocol.trusted(url), url.host?.lowercased() == "pan.xunlei.com",
                      let scriptURL = Bundle.main.url(forResource: "xunlei-credentials", withExtension: "js") else { throw CloudError.message("请先在迅雷网盘页面完成登录。") }
                let script = try String(contentsOf: scriptURL, encoding: .utf8)
                guard var object = try await view.evaluateJavaScript(script) as? [String: Any], let currentURL = view.url, XunleiProtocol.trusted(currentURL), currentURL.host?.lowercased() == "pan.xunlei.com" else { throw CloudError.message("尚未取得完整登录态，请完成官网登录后重试。") }
                let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                    view.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
                }
                if XunleiProtocol.string(object["device_id"]).isEmpty,
                   let device = cookies.first(where: { cookie in
                       let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                       return cookie.name == "deviceid" && (domain == "xunlei.com" || domain.hasSuffix(".xunlei.com"))
                   }) {
                    let parts = device.value.split(separator: ".")
                    object["device_id"] = parts.count > 1 ? String(parts[1].prefix(32)) : device.value
                }
                credential = try XunleiWebCredential(object: object)
            }
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 30
            let session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let client = XunleiClient(token: credential.access, fields: credential.fields, session: session)
            let name = try await client.validate()
            try Task.checkCancellation()
            vault.add(platform: "迅雷", remark: name, secret: client.accessToken, fields: client.backupFields)
            if let error = vault.message { state.failure = error } else { self.imported = ""; dismiss() }
        } catch { if !Task.isCancelled { state.failure = error is CloudError ? error.localizedDescription : "迅雷登录验证失败，请完成官网登录并检查网络。" } }
    }
}

@MainActor
private struct XunleiAuthWebView: UIViewRepresentable {
    @ObservedObject var state: WebLoginState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.customUserAgent = XunleiProtocol.webAgent; view.allowsBackForwardNavigationGestures = true
        state.webView = view; view.load(URLRequest(url: URL(string: "https://pan.xunlei.com/")!))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: WebLoginState
        init(state: WebLoginState) { self.state = state }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" || XunleiProtocol.trusted(url) { decisionHandler(.allow) }
            else { state.failure = "此跳转不属于受信任的迅雷 HTTPS 页面，请使用网页内的其他登录方式。"; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url, XunleiProtocol.trusted(url) { webView.load(navigationAction.request) }
            return nil
        }
    }
}
