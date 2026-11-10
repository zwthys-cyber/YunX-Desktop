// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

final class XHSImageResolver {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 12
            self.session = URLSession(configuration: config, delegate: MediaNoRedirect(), delegateQueue: nil)
        }
    }
    deinit { session.invalidateAndCancel() }
    static func candidate(_ original: URL) -> URL? {
        guard let host = original.host?.lowercased(), host == "xhscdn.com" || host.hasSuffix(".xhscdn.com"),
              host != "sns-img-bd.xhscdn.com", let parts = URLComponents(url: original, resolvingAgainstBaseURL: false) else { return nil }
        let paths = parts.percentEncodedPath.split(separator: "/")
        guard paths.count >= 3 else { return nil }
        let identifier = paths.dropFirst(2).joined(separator: "/").components(separatedBy: "!").first ?? ""
        guard !identifier.isEmpty else { return nil }
        return URL(string: "https://sns-img-bd.xhscdn.com/" + identifier)
    }
    private static func check(_ index: Int, asset: MediaAsset, session: URLSession) async throws -> (Int, MediaAsset, Bool) {
        try Task.checkCancellation()
        guard let candidate = Self.candidate(asset.url), candidate != asset.url else { return (index, asset, false) }
        var request = URLRequest(url: candidate)
        request.httpMethod = "HEAD"
        for (key, value) in asset.headers where ["referer", "user-agent"].contains(key.lowercased()) { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (_, response) = try await session.data(for: request)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.mimeType?.lowercased().hasPrefix("image/") == true {
                let original = MediaAsset(id: asset.id, url: candidate, previewURL: nil, filename: asset.filename,
                                          label: "原图候选已确认", size: nil, kind: .image, headers: asset.headers)
                return (index, original, false)
            }
        } catch { if Task.isCancelled { throw CancellationError() } }
        return (index, asset, true)
    }
    func resolve(_ result: MediaResult) async throws -> MediaResult {
        var output = result
        var revised = result.assets
        var fallback = 0
        let imageIndices = result.assets.indices.filter { result.assets[$0].kind == .image }
        try await withThrowingTaskGroup(of: (Int, MediaAsset, Bool).self) { group in
            var pending = imageIndices.makeIterator()
            for _ in 0..<4 {
                if let index = pending.next() {
                    let asset = result.assets[index]
                    group.addTask { [session] in try await Self.check(index, asset: asset, session: session) }
                }
            }
            for try await (index, asset, usedFallback) in group {
                revised[index] = asset
                if usedFallback { fallback += 1 }
                if let next = pending.next() {
                    let candidate = result.assets[next]
                    group.addTask { [session] in try await Self.check(next, asset: candidate, session: session) }
                }
            }
        }
        output.assets = revised
        if fallback > 0 { output.notice = "\(fallback) 张图片未能确认原图候选可用，已保留平台图片地址（可能带水印）。" }
        return output
    }
}
