// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

@MainActor
struct NetworkProxyScreen: View {
    @ObservedObject var downloads: DownloadStore
    @State private var profile = NetworkProxyProfile()
    @State private var port = "8080"
    @State private var message: String?
    @State private var saving = false
    var body: some View {
        Form {
            Section("API、网页与 HTTP(S) 下载") {
                Picker("网络模式", selection: $profile.mode) {
                    ForEach(NetworkProxyProfile.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if profile.mode == .manual {
                    Picker("代理协议", selection: $profile.scheme) { ForEach(NetworkProxyProfile.Scheme.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) } }
                    TextField("主机（不含协议和端口）", text: $profile.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("端口", text: $port).keyboardType(.numberPad)
                    TextField("代理用户名（可选）", text: $profile.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("代理密码", text: $profile.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("保存并应用到新连接") { Task { await save() } }.disabled(saving)
                Button("重新读取已保存设置", action: load).disabled(saving)
                if saving { ProgressView() }
                if let message { Text(message).font(.footnote) }
            }
            Section {
                Text("主机、用户名和密码保存在此设备钥匙串。手动代理不可用时连接失败，不自动改为直连。新网页会话和请求使用保存的设置；已开始的传输可继续使用原连接。")
                Text("系统网络下的公开 HTTPS 支持后台传输；手动代理和应用直连使用前台会话。网页在「原生请求直连」模式下仍遵循系统网络。")
                Text("原生引擎按每个 HTTP 请求读取系统或手动代理；不把代理凭据写入引擎数据库。系统 PAC 仅由原生网页与 URLSession 处理，引擎需改为手动代理。P2P 对等连接、DHT 和 UDP 不受此 HTTP 代理设置控制。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("网络代理").onAppear(perform: load)
    }
    private func load() {
        do { profile = try NetworkProxy.reload(); port = String(profile.port); downloads.refreshForegroundNetworking(); message = nil }
        catch { message = error is NetworkProxyError ? error.localizedDescription : "代理设置无法读取，请重试。" }
    }
    private func save() async {
        guard !saving else { return }; saving = true; defer { saving = false }
        do {
            if profile.mode == .manual { guard let value = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { throw NetworkProxyError.invalid }; profile.port = value }
            profile = try profile.validated()
            try NetworkProxy.save(profile)
            downloads.refreshForegroundNetworking()
            try await NativeEngine.shared.refreshNetworkProxy()
            message = "已保存，新连接使用此设置；重新打开网页或重启应用可统一现有会话。"
        } catch { message = error is NetworkProxyError ? error.localizedDescription : "代理已保存，但部分现有连接未能更新；请重启应用。" }
    }
}
