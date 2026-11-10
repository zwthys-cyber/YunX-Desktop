// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CryptoKit
import Network
@testable import YunX

private final class NativeHTTPFixture {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "YunX.Tests.HTTP")
    private let data: Data
    private var starts: [Int] = []
    private var clients: [NWConnection] = []
    init(data: Data) throws {
        self.data = data
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed, let self else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/fixture.bin")!)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.clients.append(connection)
                connection.start(queue: self.queue)
                self.read(connection, input: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func read(_ connection: NWConnection, input: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] part, _, ended, error in
            guard let self, error == nil else { connection.cancel(); return }
            let input = input + (part ?? Data())
            guard input.count <= 16_384 else { connection.cancel(); return }
            guard input.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if ended { connection.cancel() } else { self.read(connection, input: input) }
                return
            }
            let text = String(decoding: input, as: UTF8.self)
            var start = 0
            var end = self.data.count - 1
            var partial = false
            if let range = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
                let value = range.components(separatedBy: "bytes=").last ?? ""
                let values = value.split(separator: "-", omittingEmptySubsequences: false)
                if values.count == 2, let offset = Int(values[0]), offset >= 0, offset < self.data.count {
                    start = offset; end = min(self.data.count - 1, Int(values[1]) ?? end); partial = true
                    self.starts.append(start)
                }
            }
            guard end >= start else { connection.cancel(); return }
            var head = "HTTP/1.1 \(partial ? 206 : 200) OK\r\nAccept-Ranges: bytes\r\nETag: \"yunx-test-fixture\"\r\nContent-Type: application/octet-stream\r\nContent-Length: \(end - start + 1)\r\nConnection: close\r\n"
            if partial { head += "Content-Range: bytes \(start)-\(end)/\(self.data.count)\r\n" }
            let body = text.hasPrefix("HEAD ") ? Data() : self.data.subdata(in: start..<(end + 1))
            connection.send(content: Data((head + "\r\n").utf8), contentContext: body.isEmpty ? .finalMessage : .defaultMessage, isComplete: body.isEmpty, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                if body.isEmpty { return }
                else if start == 0 { self.stream(body, offset: 0, connection: connection) }
                else { connection.send(content: body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in if error != nil { connection.cancel() } }) }
            })
        }
    }
    private func stream(_ body: Data, offset: Int, connection: NWConnection) {
        let end = min(body.count, offset + 65_536)
        let last = end == body.count
        connection.send(content: body.subdata(in: offset..<end), contentContext: last ? .finalMessage : .defaultMessage,
                        isComplete: last, completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            if !last { self.queue.asyncAfter(deadline: .now() + .milliseconds(5)) { self.stream(body, offset: end, connection: connection) } }
        })
    }
    func stop() { queue.sync { listener.cancel(); clients.forEach { $0.cancel() }; clients.removeAll() } }
    var usedNonzeroRange: Bool { queue.sync { starts.contains { $0 > 0 } } }
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
                let deadline = Date().addingTimeInterval(45)
                while Date() < deadline {
                    let tasks = try await NativeEngine.shared.tasks()
                    if let task = tasks.first(where: { $0.id == id }), ["done", "error"].contains(task.status) { terminal = task; break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let task = try XCTUnwrap(terminal, "Native fixture download timed out")
                if expected == digest {
                    if task.status != "done" {
                        // Test sandbox contains synthetic fixtures only, never real account requests.
                        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        let log = (try? Data(contentsOf: support.appendingPathComponent("YunX/Engine/logs/core.log"))) ?? Data()
                        XCTFail("Native fixture failed: " + String(decoding: log.suffix(16_384), as: UTF8.self))
                    }
                    let file = try XCTUnwrap(NativeEngine.shared.completedFiles(task).first)
                    XCTAssertEqual(try Data(contentsOf: file), content)
                    XCTAssertTrue(fixture.usedNonzeroRange)
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
