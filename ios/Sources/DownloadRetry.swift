// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

enum DownloadRetry {
    static func delay(attempt: Int, status: Int? = nil, error: NSError? = nil, retryAfter: String? = nil) -> TimeInterval? {
        guard (0..<3).contains(attempt) else { return nil }
        let temporaryHTTP = status.map { [408, 429, 500, 502, 503, 504].contains($0) } ?? false
        let temporaryNetwork = error.map { $0.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains($0.code) } ?? false
        guard temporaryHTTP || temporaryNetwork else { return nil }
        var delay = pow(2, Double(attempt + 1))
        if let retryAfter, let seconds = Double(retryAfter), seconds.isFinite, seconds >= 0 { delay = max(delay, min(300, seconds)) }
        return delay
    }
}
