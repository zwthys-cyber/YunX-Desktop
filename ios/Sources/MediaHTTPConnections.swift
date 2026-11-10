// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum MediaHTTPConnections {
    static func key(_ provider: MediaProvider) -> String { "mediaHTTPConnections." + provider.rawValue }
    static func nativeKey(_ provider: MediaProvider) -> String { "mediaNativeFiles." + provider.rawValue }
    static func nativeFiles(_ provider: MediaProvider) -> Bool { UserDefaults.standard.bool(forKey: nativeKey(provider)) }
    static func value(_ provider: MediaProvider) -> Int {
        let count = UserDefaults.standard.integer(forKey: key(provider))
        return (1...512).contains(count) ? count : 4
    }
}

struct MediaHTTPConnectionSettings: View {
    let provider: MediaProvider
    @AppStorage private var connections: Int
    @AppStorage private var nativeFiles: Bool
    init(provider: MediaProvider) {
        self.provider = provider
        _connections = AppStorage(wrappedValue: 4, MediaHTTPConnections.key(provider))
        _nativeFiles = AppStorage(wrappedValue: false, MediaHTTPConnections.nativeKey(provider))
    }
    var body: some View {
        Toggle("普通文件使用原生多连接（前台）", isOn: $nativeFiles)
        Stepper("\(provider.rawValue)每个源文件：\(connections) 个连接", value: $connections, in: 1...512)
            .onAppear { if !(1...512).contains(connections) { connections = 4 } }
        Text("连接数用于合轨、片段拼接、动态照片及已启用原生模式的普通图片/视频文件；HLS 不应用此设置。原生普通文件在引擎队列查看，使用原生 HTTP 限速与代理，完成前检查媒体内容；系统模式保留后台策略。更改只影响新任务。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
