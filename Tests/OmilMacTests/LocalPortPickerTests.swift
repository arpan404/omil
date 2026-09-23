import XCTest
@testable import OmilMac

final class LocalPortPickerTests: XCTestCase {
    func testUsesDefaultPairWhenBothPortsAreFree() {
        let result = LocalPortPicker.choose(identity: "/Applications/Omil.app") { _ in true }
        XCTAssertEqual(result, LocalServerPorts(api: 3217, llama: 3218))
    }

    func testUsesStableAlternatePairWhenAnotherServerOwnsTheDefault() {
        let free: (Int) -> Bool = { $0 != 3217 }
        let first = LocalPortPicker.choose(identity: "/Applications/Omil.app", isFree: free)
        let again = LocalPortPicker.choose(identity: "/Applications/Omil.app", isFree: free)
        let other = LocalPortPicker.choose(identity: "/Applications/Other.app", isFree: free)

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertNotEqual(first?.api, 3217)
        XCTAssertEqual(first?.llama, (first?.api ?? 0) + 1)
    }

    func testSkipsAnOccupiedModelSidecarPort() {
        let initial = LocalPortPicker.choose(identity: "/Applications/Omil.app") { $0 != 3218 }
        let occupied = initial?.llama
        let result = LocalPortPicker.choose(identity: "/Applications/Omil.app") {
            $0 != 3218 && $0 != occupied
        }

        XCTAssertNotNil(result)
        XCTAssertNotEqual(result, initial)
        XCTAssertNotEqual(result?.llama, occupied)
    }

    func testReportsWhenNoPairIsFree() {
        XCTAssertNil(LocalPortPicker.choose(identity: "/Applications/Omil.app") { _ in false })
    }
}
