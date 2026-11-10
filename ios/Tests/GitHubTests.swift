// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class GitHubTests: XCTestCase {
    func testCommitDateUsesExactDirectoryAndSelectedBranch() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/commits")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "path", value: "中文 folder/sub")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "sha", value: "release/mobile")))
            return (200, [:], [["commit": ["committer": ["date": "2026-01-02T03:04:05Z"]]]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        var repo = GitHubRepository(owner: "owner", name: "repo"); repo.ref = "release/mobile"
        let date = try await client.latestCommitDate(repo, path: "中文 folder/sub")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
    }
    func testArchivePinsSlashBranchToCommitAndKeepsTokenOnOfficialAPI() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        let sha = String(repeating: "a", count: 40)
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer archive-token")
            if request.url?.path.hasSuffix("/commits") == true {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains(URLQueryItem(name: "sha", value: "feature/中文")))
                XCTAssertTrue(query.contains(URLQueryItem(name: "per_page", value: "1")))
                return (200, [:], [["sha": sha]])
            }
            return (200, [:], ["full_name": "owner/repo", "default_branch": "main", "fork": true,
                              "parent": ["full_name": "upstream/original"]])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(token: "archive-token", session: URLSession(configuration: config))
        var repo = GitHubRepository(owner: "owner", name: "repo"); repo.ref = "feature/中文"
        let detail = try await client.repositoryDetail(repo)
        XCTAssertEqual(detail.parent?.full_name, "upstream/original")
        let plan = try await client.archiveDownload(repo)
        XCTAssertEqual(plan.url.absoluteString, "https://api.github.com/repos/owner/repo/zipball/" + sha)
        XCTAssertEqual(plan.filename, "repo-aaaaaaaaaaaa.zip")
        XCTAssertEqual(plan.headers["Authorization"], "Bearer archive-token")
        XCTAssertFalse(GitHubMirrorPolicy.publicOrigin(plan.url))
    }
    func testEmptyRepositoryCannotQueueAnUnpinnedArchive() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            if request.url?.path.hasSuffix("/commits") == true { return (200, [:], []) }
            return (200, [:], ["full_name": "owner/repo", "default_branch": "main", "fork": false])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        do { _ = try await client.archiveDownload(GitHubRepository(owner: "owner", name: "repo")); XCTFail("Empty archive accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("提交")) }
    }
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

final class GitHubHTMLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw CloudError.message("No live network in tests") }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

extension GitHubTests {
    func testReadmeHTMLUsesGitHubRenderingAndRejectsErrorBodies() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GitHubHTMLProtocol.self]
        let html = "<table><tr><td>测试</td></tr></table><details><summary>更多</summary>内容</details>"
        GitHubHTMLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.html+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, Data(html.utf8))
        }
        defer { GitHubHTMLProtocol.handler = nil }
        let client = GitHubClient(token: "test-token", session: URLSession(configuration: config))
        let repo = GitHubRepository(owner: "owner", name: "repo")
        let actual = try await client.readmeHTML(repo)
        XCTAssertEqual(actual, html)
        GitHubHTMLProtocol.handler = { _ in (403, Data("test-token private-server-text".utf8)) }
        do {
            _ = try await client.readmeHTML(repo)
            XCTFail("Expected rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("test-token"))
            XCTAssertFalse(error.localizedDescription.contains("private-server-text"))
        }
    }
}

extension GitHubTests {
    func testTreeLinkConfirmsSlashBranchAndKeepsRefForDirectoryAndReadme() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if request.url?.path.hasSuffix("/commits") == true {
                let sha = query.first { $0.name == "sha" }?.value
                if sha == "feature/new" { return (200, [:], [["sha": "test-commit"]]) }
                return (404, [:], [:])
            }
            XCTAssertEqual(query.first { $0.name == "ref" }?.value, "feature/new")
            if request.url?.path.hasSuffix("/readme") == true { return (200, [:], ["encoding": "base64", "content": Data("branch readme".utf8).base64EncodedString()]) }
            XCTAssertEqual(request.url?.path, "/repos/owner/repo/contents/src/中文")
            return (200, [:], [])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        let input = try GitHubInput.parse("https://github.com/owner/repo/tree/feature/new/src/中文?unneeded=value")
        let repo = try await client.resolve(input)
        XCTAssertEqual(repo.ref, "feature/new")
        XCTAssertEqual(repo.initialPath, "src/中文")
        XCTAssertFalse(repo.initialFile)
        XCTAssertFalse(repo.historyText.contains("unneeded"))
        let files = try await client.contents(repo, path: repo.initialPath)
        XCTAssertTrue(files.isEmpty)
        let readme = try await client.readme(repo)
        XCTAssertEqual(readme, "branch readme")
    }
    func testBlobLinkAndAuthorizationErrorsNeverFallBackToDefaultBranch() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            let sha = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "sha" }?.value
            if sha == "main" { return (200, [:], [["sha": "test-commit"]]) }
            return (404, [:], [:])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(session: URLSession(configuration: config))
        let input = try GitHubInput.parse("https://github.com/owner/repo/blob/main/docs/file.txt")
        let repo = try await client.resolve(input)
        XCTAssertTrue(repo.initialFile); XCTAssertEqual(repo.initialPath, "docs/file.txt")
        MediaMockProtocol.handler = { _ in (403, [:], ["message": "test-token must not appear"]) }
        do { _ = try await client.resolve(input); XCTFail("Permission failure must stop ref resolution") }
        catch let error as GitHubAPIError { XCTAssertEqual(error.status, 403); XCTAssertFalse(error.localizedDescription.contains("test-token")) }
        catch { XCTFail("Unexpected error type") }
        XCTAssertThrowsError(try GitHubInput.parse("https://github.com.evil.test/owner/repo/tree/main"))
    }
    func testPrivateFileAndReleasePlansSendTokenOnlyToOfficialAPI() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaMockProtocol.self]
        MediaMockProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.object+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, [:], ["name": "file.txt", "path": "docs/file.txt", "type": "file", "size": 3, "download_url": NSNull()])
        }
        defer { MediaMockProtocol.handler = nil }
        let client = GitHubClient(token: "test-token", session: URLSession(configuration: config))
        var repo = GitHubRepository(owner: "owner", name: "repo"); repo.ref = "feature/new"
        let plan = try await client.fileDownload(repo, path: "docs/file.txt")
        XCTAssertEqual(plan.url.host, "api.github.com")
        XCTAssertEqual(plan.headers["Accept"], "application/vnd.github.raw+json")
        XCTAssertEqual(URLComponents(url: plan.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "feature/new")
        let target = URL(string: "https://release-assets.githubusercontent.com/file")!
        XCTAssertNil(DownloadHeaders.redirectHeaders(plan.headers, original: plan.url, target: target)["Authorization"])
        let asset = GitHubRelease.Asset(id: 42, name: "asset.bin", size: 3, browser_download_url: URL(string: "https://github.com/owner/repo/releases/download/v1/asset.bin")!)
        let release = try await client.releaseDownload(repo, asset: asset)
        XCTAssertEqual(release.url.path, "/repos/owner/repo/releases/assets/42")
        XCTAssertEqual(release.headers["Accept"], "application/octet-stream")
        XCTAssertEqual(release.headers["Authorization"], "Bearer test-token")
        XCTAssertNil(DownloadHeaders.redirectHeaders(release.headers, original: release.url, target: target)["Authorization"])
    }
}
