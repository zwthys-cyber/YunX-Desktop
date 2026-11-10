// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import YunX

private actor NotificationCounts {
    var values: [Int] = []
    func add(_ count: Int) { values.append(count) }
}

final class DownloadNotificationTests: XCTestCase {
    func testNearbyCompletionsUpdateSummaryInOrderWithoutRequestingSystemPermission() async {
        let delivered = expectation(description: "coalesced completion")
        delivered.expectedFulfillmentCount = 2
        delivered.assertForOverFulfill = true
        let counts = NotificationCounts()
        let notifications = DownloadNotifications(enabled: { true }, delivery: { count in
            await counts.add(count)
            delivered.fulfill()
        })
        await notifications.completed()
        await notifications.completed()
        await fulfillment(of: [delivered], timeout: 2)
        let values = await counts.values
        XCTAssertEqual(values, [1, 2])
    }
    func testDisabledNotificationsNeverScheduleDelivery() async {
        let delivered = expectation(description: "no completion while disabled")
        delivered.isInverted = true
        let notifications = DownloadNotifications(enabled: { false }, delivery: { _ in delivered.fulfill() })
        await notifications.completed()
        await fulfillment(of: [delivered], timeout: 0.15)
    }
}
