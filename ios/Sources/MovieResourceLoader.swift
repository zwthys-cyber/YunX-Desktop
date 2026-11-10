// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct MovieContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64?

    static func parse(_ text: String) -> MovieContentRange? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let values = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard values.count == 2 else { return nil }
        let interval = values[0].split(separator: "-", omittingEmptySubsequences: false)
        guard interval.count == 2, let start = Int64(interval[0]), let end = Int64(interval[1]),
              start >= 0, end >= start else { return nil }
        let total: Int64?
        if values[1] == "*" { total = nil }
        else {
            guard let size = Int64(values[1]), size > end else { return nil }
            total = size
        }
        return MovieContentRange(start: start, end: end, total: total)
    }

    static func header(offset: Int64, length: Int64?) -> String? {
        guard offset >= 0 else { return nil }
        guard let length else { return "bytes=\(offset)-" }
        guard length > 0 else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(length - 1)
        return overflow ? nil : "bytes=\(offset)-\(end)"
    }
}

/// Progressive MP4 playback via public AVAssetResourceLoader APIs.
/// Delegate callbacks run on the main queue; URLSession streams bytes rather than buffering whole videos.
final class MovieResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private final class Pending {
        let loading: AVAssetResourceLoadingRequest
        let start: Int64
        let length: Int64?
        var delivered: Int64 = 0
        var skip: Int64 = 0
        var total: Int64?
        init(_ loading: AVAssetResourceLoadingRequest, start: Int64, length: Int64?) {
            self.loading = loading; self.start = start; self.length = length
        }
    }
    private let url: URL
    private let headers: [String: String]
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    private var closed = false

    init(url: URL, headers: [String: String]) {
        self.url = url; self.headers = headers
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        session = NetworkProxy.session(configuration: config, delegate: self, delegateQueue: .main)
    }

    func asset() -> AVURLAsset {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "yunx-mp4"
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: .main)
        return asset
    }

    func close() {
        guard !closed else { return }
        closed = true
        let requests = Array(pending.values)
        pending.removeAll()
        session.invalidateAndCancel()
        for request in requests { request.loading.finishLoading(with: failure("播放已关闭。")) }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "YunX.Movie", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !closed else { return false }
        let data = loadingRequest.dataRequest
        let start = data.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let remaining: Int64?
        if let data, !data.requestsAllDataToEndOfResource {
            remaining = Int64(data.requestedLength) - (start - data.requestedOffset)
        } else { remaining = data == nil ? 2 : nil }
        if remaining == 0 { loadingRequest.finishLoading(); return true }
        guard let range = MovieContentRange.header(offset: start, length: remaining) else {
            loadingRequest.finishLoading(with: failure("播放区间无效。")); return true
        }
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = Pending(loadingRequest, start: start, length: data == nil ? nil : remaining)
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let ids = pending.filter { $0.value.loading === loadingRequest }.map(\.key)
        for id in ids {
            pending.removeValue(forKey: id)
            session.getAllTasks { tasks in tasks.first(where: { $0.taskIdentifier == id })?.cancel() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let request = pending[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
              [200, 206].contains(http.statusCode) else {
            fail(dataTask, "视频服务器拒绝播放请求。")
            completionHandler(.cancel); return
        }
        let mime = (http.mimeType ?? "").lowercased()
        guard !mime.hasPrefix("text/"), !mime.contains("json") else {
            fail(dataTask, "视频地址返回了验证页，请重新解析。")
            completionHandler(.cancel); return
        }
        if http.statusCode == 206 {
            guard let raw = http.value(forHTTPHeaderField: "Content-Range"),
                  let range = MovieContentRange.parse(raw), range.start == request.start else {
                fail(dataTask, "视频服务器返回了错误的播放区间。")
                completionHandler(.cancel); return
            }
            request.total = range.total
        } else {
            request.skip = request.start
            request.total = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
        }
        if let info = request.loading.contentInformationRequest {
            info.contentType = UTType.mpeg4Movie.identifier
            if let total = request.total { info.contentLength = total }
            info.isByteRangeAccessSupported = true
        }
        if request.loading.dataRequest == nil {
            pending.removeValue(forKey: dataTask.taskIdentifier)
            request.loading.finishLoading()
            completionHandler(.cancel)
        } else { completionHandler(.allow) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let request = pending[dataTask.taskIdentifier], let output = request.loading.dataRequest else { return }
        let dropped = min(Int64(data.count), request.skip)
        request.skip -= dropped
        let remaining = request.length.map { max(0, $0 - request.delivered) } ?? Int64.max
        let count = min(Int64(data.count) - dropped, remaining)
        if count > 0 {
            output.respond(with: data.subdata(in: Int(dropped)..<Int(dropped + count)))
            request.delivered += count
        }
        if let length = request.length, request.delivered >= length {
            pending.removeValue(forKey: dataTask.taskIdentifier)
            request.loading.finishLoading()
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let request = pending.removeValue(forKey: task.taskIdentifier) else { return }
        let atEOF = request.total.map { request.start + request.delivered >= $0 } ?? false
        if error == nil && (request.length == nil || atEOF || request.delivered >= (request.length ?? 0)) {
            request.loading.finishLoading()
        } else { request.loading.finishLoading(with: failure("视频数据中断，请重试或重新解析。")) }
    }

    private func fail(_ task: URLSessionTask, _ message: String) {
        pending.removeValue(forKey: task.taskIdentifier)?.loading.finishLoading(with: failure(message))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.scheme?.lowercased() == "https" else {
            completionHandler(nil); return
        }
        var redirected = request
        for key in ["Cookie", "Authorization", "Proxy-Authorization"] { redirected.setValue(nil, forHTTPHeaderField: key) }
        for (key, value) in DownloadHeaders.redirectHeaders(headers, original: url, target: target) {
            redirected.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(redirected)
    }
}
