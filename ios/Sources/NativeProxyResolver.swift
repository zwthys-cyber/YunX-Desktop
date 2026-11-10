// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Yunxengine

final class IOSProxyResolver: NSObject, YunxengineProxyResolverProtocol, @unchecked Sendable {
    private let fixed: NetworkProxyProfile?
    init(profile: NetworkProxyProfile? = nil) { fixed = profile; super.init() }
    func resolve(_ rawURL: String?) -> String { NetworkProxy.runtimeJSON(for: rawURL ?? "", fixed: fixed) }
}
