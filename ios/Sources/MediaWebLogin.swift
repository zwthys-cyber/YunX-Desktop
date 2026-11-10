// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import WebKit

@MainActor
struct MediaWebLogin: View {
    let provider: MediaProvider
    @ObservedObject var vault: CredentialVault
    @StateObject private var state = WebLoginState()
    @State private var saveTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在官方页面完成登录后保存。每次使用独立临时会话，可分别添加不同账号。")
                    .font(.footnote).foregroundStyle(.secondary).padding()
                if let failure = state.failure { Text(failure).foregroundStyle(.red).font(.footnote).padding(.horizontal) }
                if state.saving { ProgressView("正在验证登录…").padding() }
                CloudLoginWebView(loginURL: provider.loginURL, userAgent: MediaClient.userAgent, state: state)
            }.navigationTitle(provider.rawValue + "登录")
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
        state.saving = true; state.failure = nil
        defer { state.saving = false }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        var values: [String: String] = [:]
        for cookie in cookies.sorted(by: { $0.domain.count < $1.domain.count }) {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            guard domain == provider.domain || domain.hasSuffix("." + provider.domain),
                  cookie.expiresDate == nil || cookie.expiresDate! > Date() else { continue }
            values[cookie.name] = cookie.value
        }
        let secret = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
        guard !secret.isEmpty else { state.failure = "尚未取得登录 Cookie，请完成登录。"; return }
        do {
            let name = try await MediaClient().validate(provider: provider, cookie: secret)
            try Task.checkCancellation()
            vault.add(platform: provider.rawValue, remark: name, secret: secret)
            if let failure = vault.message { state.failure = failure }
            else { dismiss() }
        } catch is CancellationError { }
        catch { state.failure = "登录验证未通过，请完成验证、检查网络或改用手动 Cookie。" }
    }
}
