import XCTest
@testable import OmilMac

final class RecentTargetAppTests: XCTestCase {
    func testOmilWindowUsesThePreviousAppForInsertion() {
        XCTAssertEqual(
            RecentTargetPolicy.preferredPID(
                source: .app, frontmostPID: 100, omilPID: 100, lastExternalPID: 200
            ),
            200
        )
    }

    func testMenuBarCanUseThePreviousApp() {
        XCTAssertEqual(
            RecentTargetPolicy.preferredPID(
                source: .menuBar, frontmostPID: 100, omilPID: 100, lastExternalPID: 200
            ),
            200
        )
    }

    func testFloatingPillUsesTheCurrentExternalApp() {
        XCTAssertEqual(
            RecentTargetPolicy.preferredPID(
                source: .pill, frontmostPID: 300, omilPID: 100, lastExternalPID: 200
            ),
            300
        )
    }

    func testShortcutDoesNotUseAnOldAppWhenOmilIsFocused() {
        XCTAssertNil(
            RecentTargetPolicy.preferredPID(
                source: .shortcut, frontmostPID: 100, omilPID: 100, lastExternalPID: 200
            )
        )
    }

    func testCurrentExternalAppWinsOverThePreviousOne() {
        XCTAssertEqual(
            RecentTargetPolicy.preferredPID(
                source: .menuBar, frontmostPID: 300, omilPID: 100, lastExternalPID: 200
            ),
            300
        )
    }
}
