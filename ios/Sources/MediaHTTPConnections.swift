// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum MediaHTTPConnections {
    static func key(_ provider: MediaProvider) -> String { "mediaHTTPConnections." + provider.rawValue }
    static func value(_ provider: MediaProvider) -> Int {
        let count = UserDefaults.standard.integer(forKey: key(provider))
        return (1...512).contains(count) ? count : 4
    }
}

struct MediaHTTPConnectionSettings: View {
    let provider: MediaProvider
    @AppStorage private var connections: Int
    init(provider: MediaProvider) {
        self.provider = provider
        _connections = AppStorage(wrappedValue: 4, MediaHTTPConnections.key(provider))
    }
    var body: some View {
        Stepper("\(provider.rawValue)每个源文件：\(connections) 个连接", value: $connections, in: 1...512)
            .onAppear { if !(1...512).contains(connections) { connections = 4 } }
        Text("仅用于合轨、片段拼接和动态照片的原生 HTTPS 源文件；普通单文件及 HLS 不应用此设置。更改只影响新任务，已有任务保留原连接数。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}
