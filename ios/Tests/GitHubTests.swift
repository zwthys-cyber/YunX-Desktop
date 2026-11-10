// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class GitHubTests: XCTestCase {
    func testRepositoryInputRejectsForeignHostsAndTraversal() throws {
        XCTAssertEqual(try GitHubRepository.parse("https://github.com/owner/repo.git"), GitHubRepository(owner: "owner", name: "repo"))
        XCTAssertEqual(try GitHubRepository.parse(" owner/repo ").apiPath, "/repos/owner/repo")
        for value in ["https://github.com.evil.test/a/b", "https://secret@github.com/a/b", "http://github.com/a/b", "a/..", "a/b/c", "a/", "a/b?token=secret"] {
            XCTAssertThrowsError(try GitHubRepository.parse(value), value)
        }
    }
    func testDirectoryEncodingAndAuthorization() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/contents/中文 folder")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, [:], [
                ["name": "z.txt", "path": "z.txt", "type": "file", "size": 10, "download_url": "https://raw.githubusercontent.com/owner/repo/main/z.txt"],
                ["name": "folder", "path": "folder", "type": "dir", "size": 0, "download_url": NSNull()]
            ])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(token: "test-token", session: URLSession(configuration: config))
        let items = try await client.contents(GitHubRepository(owner: "owner", name: "repo"), path: "中文 folder")
        XCTAssertEqual(items.map(\.type), ["dir", "file"])
    }
    func testReadmeDecodeAndReleasePagination() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path.hasSuffix("/readme") {
                return (200, [:], ["encoding": "base64", "content": Data("# 云析".utf8).base64EncodedString() + "\n"])
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "page", value: "2")))
            return (200, [:], [["id": 2, "tag_name": "v2", "assets": []]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        let repo = GitHubRepository(owner: "owner", name: "repo")
        let readme = try await client.readme(repo)
        XCTAssertEqual(readme, "# 云析")
        let releases = try await client.releases(repo, page: 2)
        XCTAssertEqual(releases.first?.tag_name, "v2")
    }
    func testOrganizationPaginationUsesFixedAPIHost() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/orgs/example/repos")
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.contains(URLQueryItem(name: "page", value: "3")))
            return (200, [:], [["id": 1, "full_name": "example/repo", "stargazers_count": 3]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        let items = try await client.repositories(owner: "example", organization: true, page: 3)
        XCTAssertEqual(items.first?.full_name, "example/repo")
        do {
            _ = try await client.repositories(owner: "../malicious", organization: false, page: 1)
            XCTFail("Expected owner rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("仓库")) }
    }
    func testErrorDoesNotExposeServerTextOrToken() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { _ in (403, [:], ["message": "secret-token private-path"]) }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(token: "secret-token", session: URLSession(configuration: config))
        do {
            _ = try await client.contents(GitHubRepository(owner: "owner", name: "repo"))
            XCTFail("Expected rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
            XCTAssertFalse(error.localizedDescription.contains("private-path"))
        }
    }
}
