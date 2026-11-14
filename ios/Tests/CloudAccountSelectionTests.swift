// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

final class CloudAccountSelectionTests: XCTestCase {
    private func account(_ secret: String = "fixture", primary: Bool? = nil, platform: String = CloudProvider.baidu.rawValue) -> SavedCredential {
        SavedCredential(platform: platform, remark: "fixture", secret: secret, isPrimary: primary)
    }
    func testSingleUnmarkedAccountIsSelected() {
        let saved = account()
        XCTAssertEqual(CloudAccountSelection.automatic([saved], provider: .baidu)?.id, saved.id)
    }
    func testAmbiguousAccountsRequireExplicitSelection() {
        XCTAssertNil(CloudAccountSelection.automatic([account(), account()], provider: .baidu))
        XCTAssertNil(CloudAccountSelection.automatic([account(primary: true), account(primary: true)], provider: .baidu))
    }
    func testPrimaryWinsAndUnusableCredentialsAreExcluded() {
        let saved = account(primary: true)
        XCTAssertEqual(CloudAccountSelection.automatic([account(), saved], provider: .baidu)?.id, saved.id)
        XCTAssertNil(CloudAccountSelection.automatic([account(" \n", primary: true), account(platform: CloudProvider.quark.rawValue)], provider: .baidu))
    }
}
