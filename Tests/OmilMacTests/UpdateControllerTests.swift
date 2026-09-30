import XCTest
import Sparkle
@testable import OmilMac

@MainActor
final class UpdateControllerTests: XCTestCase {
    private func item() throws -> SUAppcastItem {
        try XCTUnwrap(SUAppcastItem(dictionary: [
            "sparkle:version": "999",
            "sparkle:shortVersionString": "9.9.9",
            "enclosure": ["url": "https://example.com/Omil.dmg", "sparkle:version": "999", "length": "100"]
        ]))
    }

    func testUpdateCallbacksPublishAvailabilityAndClearWhenUpToDate() throws {
        let controller = UpdateController(startingUpdater: false, publicKey: Data(repeating: 1, count: 32).base64EncodedString())
        let driver = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let update = try item()
        controller.updater(driver.updater, didFindValidUpdate: update)
        XCTAssertEqual(controller.availableVersion, "9.9.9")
        controller.updaterDidNotFindUpdate(driver.updater)
        XCTAssertNil(controller.availableVersion)
    }

    func testScheduledReminderUsesSidebarAndCorrectDelegateSelectors() throws {
        let controller = UpdateController(startingUpdater: false, publicKey: Data(repeating: 1, count: 32).base64EncodedString())
        XCTAssertTrue(controller.supportsGentleScheduledUpdateReminders)
        XCTAssertFalse(controller.standardUserDriverShouldHandleShowingScheduledUpdate(try item(), andInImmediateFocus: false))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("updater:userDidMakeChoice:forUpdate:state:")))
        XCTAssertTrue(controller.responds(to: NSSelectorFromString("standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:")))
    }

    func testInvalidKeyDisablesUpdateActionsSafely() {
        let controller = UpdateController(startingUpdater: false, publicKey: "invalid")
        XCTAssertFalse(controller.canCheckForUpdates)
        controller.checkForUpdates()
        controller.refreshAvailabilityIfNeeded()
        XCTAssertNil(controller.availableVersion)
    }
}
