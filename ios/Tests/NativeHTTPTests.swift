// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CryptoKit
import Darwin
@testable import YunX

final class NativeHTTPFixture {
    private let listener: Int32
    private let data: Data
    private let observer: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var stopped = false
    private var failuresRemaining: Int
    private let requiredHeader: String?
    private let redirectTo: URL?
    private var starts: [Int] = []
    private var clients = Set<Int32>()
    private let port: UInt16
    init(data: Data, failures: Int = 0, requiredHeader: String? = nil, redirectTo: URL? = nil, observer: (@Sendable (String) -> Void)? = nil) throws {
        self.data = data
        self.failuresRemaining = failures
        self.observer = observer
        self.requiredHeader = requiredHeader; self.redirectTo = redirectTo
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw CloudError.message("Fixture socket failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(socket, 32) == 0 else { Darwin.close(socket); throw CloudError.message("Fixture bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) }
        }
        guard named == 0 else { Darwin.close(socket); throw CloudError.message("Fixture port failed") }
        listener = socket
        port = UInt16(bigEndian: address.sin_port)
    }
    func start() async throws -> URL {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = Darwin.accept(listener, nil, nil)
                if client < 0 { return }
                lock.lock()
                if stopped { lock.unlock(); Darwin.close(client); return }
                clients.insert(client)
                lock.unlock()
                var enabled: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
                DispatchQueue.global(qos: .utility).async { [self] in serve(client) }
            }
        }
        return URL(string: "http://127.0.0.1:\(port)/fixture.bin")!
    }
    private func serve(_ socket: Int32) {
        defer {
            lock.lock(); clients.remove(socket); lock.unlock()
            Darwin.shutdown(socket, SHUT_WR)
            Darwin.close(socket)
        }
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.range(of: Data("\r\n\r\n".utf8)) == nil {
            let received = Darwin.recv(socket, &buffer, buffer.count, 0)
            guard received > 0 else { return }
            input.append(contentsOf: buffer.prefix(received))
            guard input.count <= 16_384 else { return }
        }
        let text = String(decoding: input, as: UTF8.self)
        observer?(text)
        if let requiredHeader, !text.contains(requiredHeader) {
            _ = write(Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), socket: socket)
            return
        }
        if let redirectTo {
            let head = "HTTP/1.1 302 Found\r\nLocation: \(redirectTo.absoluteString)\r\nSet-Cookie: fixture-session=not-for-other-origins; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = write(Data(head.utf8), socket: socket)
            return
        }
        lock.lock()
        let fail = failuresRemaining > 0
        if fail { failuresRemaining -= 1 }
        lock.unlock()
        if fail {
            _ = write(Data("HTTP/1.1 503 Unavailable\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), socket: socket)
            return
        }
        var start = 0
        var end = data.count - 1
        var partial = false
        if let range = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = range.components(separatedBy: "bytes=").last ?? ""
            let values = value.split(separator: "-", omittingEmptySubsequences: false)
            guard values.count == 2, let offset = Int(values[0]), offset >= 0, offset < data.count else { return }
            start = offset; end = min(data.count - 1, Int(values[1]) ?? end); partial = true
            lock.lock(); starts.append(start); lock.unlock()
        }
        guard end >= start else { return }
        var head = "HTTP/1.1 \(partial ? 206 : 200) OK\r\nAccept-Ranges: bytes\r\nETag: \"yunx-test-fixture\"\r\nContent-Type: application/octet-stream\r\nContent-Length: \(end - start + 1)\r\nConnection: close\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n" }
        guard write(Data((head + "\r\n").utf8), socket: socket) else { return }
        if text.hasPrefix("HEAD ") { return }
        var offset = start
        while offset <= end {
            let next = min(end + 1, offset + 65_536)
            guard write(data.subdata(in: offset..<next), socket: socket) else { return }
            offset = next
            // Keep the first connection slow enough to exercise nonzero Range workers.
            if start == 0 { Thread.sleep(forTimeInterval: 0.005) }
        }
    }
    private func write(_ bytes: Data, socket: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.send(socket, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
        lock.unlock()
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }
    var usedNonzeroRange: Bool {
        lock.lock(); defer { lock.unlock() }
        return starts.contains { $0 > 0 }
    }
}

@MainActor
final class NativeHTTPTests: XCTestCase {
    func testNativeRequestRejectsUnsafeURLsAndInvalidChecksums() throws {
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "http://example.test/file"))
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "https://user:password@example.test/file"))
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "https://example.test/main.m3u8"))
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "https://example.test/file", checksum: "invalid"))
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "https://example.test/file", connections: 513))
        XCTAssertThrowsError(try NativeHTTPSRequest(text: "https://example.test/file", headers: ["Authorization": "test-only"]))
    }
    func testRealNativeRangeDownloadAndExpectedSHA256Rejection() async throws {
        let content = Data(repeating: 0xab, count: 8 * 1024 * 1024)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let fixture = try NativeHTTPFixture(data: content)
        let url = try await fixture.start()
        defer { fixture.stop() }
        for expected in [digest, String(repeating: "0", count: 64)] {
            let folder = NativeEngine.shared.downloads.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let request: [String: Any] = ["req": ["url": url.absoluteString], "opts": ["path": folder.path, "name": "fixture.bin", "skipAutoCategorize": true,
                "extra": ["connections": 4, "checksum": ["algorithm": "sha256", "expected": expected]]]]
            // Loopback HTTP is limited to this fixture; the production UI accepts HTTPS only.
            let created = try await NativeEngine.shared.invoke("POST", path: "/api/v1/tasks", body: JSONSerialization.data(withJSONObject: request))
            let id = try XCTUnwrap(JSONDecoder().decode(EngineEnvelope<String>.self, from: created).data)
            do {
                var terminal: EngineTask?
                var last: EngineTask?
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline {
                    let tasks = try await NativeEngine.shared.tasks()
                    last = tasks.first(where: { $0.id == id })
                    if let task = last, ["done", "error"].contains(task.status) { terminal = task; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let log = (try? Data(contentsOf: support.appendingPathComponent("YunX/Engine/logs/core.log"))) ?? Data()
                let details = String(decoding: log.suffix(16_384), as: UTF8.self)
                let task = try XCTUnwrap(terminal, "Native fixture timeout: state=\(last?.status ?? "missing"), received=\(last?.progress?.downloaded ?? -1). " + details)
                if expected == digest {
                    if task.status != "done" {
                        // Test sandbox contains synthetic fixtures only, never real account requests.
                        XCTFail("Native fixture failed: " + details)
                    }
                    let file = try XCTUnwrap(NativeEngine.shared.completedFiles(task).first)
                    XCTAssertEqual(try Data(contentsOf: file), content)
                    XCTAssertTrue(fixture.usedNonzeroRange)
                    let snapshot = try await NativeEngine.shared.invoke("GET", path: "/api/v1/tasks/" + id + "/stats")
                    let stats = try JSONDecoder().decode(EngineEnvelope<EnginePeerStats>.self, from: snapshot).data
                    XCTAssertFalse(try XCTUnwrap(stats?.snapshot?.connections).isEmpty)
                } else {
                    XCTAssertEqual(task.status, "error")
                    XCTAssertTrue(NativeEngine.shared.completedFiles(task).isEmpty)
                }
                _ = try await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + id, query: "force=true")
            } catch {
                _ = try? await NativeEngine.shared.invoke("DELETE", path: "/api/v1/tasks/" + id, query: "force=true")
                throw error
            }
        }
    }
}
