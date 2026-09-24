import XCTest
@testable import OmilMac

final class DiffUtilTests: XCTestCase {
    func testComparesRawAndFinalPlainTextIncludingPunctuation() {
        let changes = DiffUtil.diff(
            raw: "kubenerties seem to work but its settings are wrong",
            cleaned: "Kubernetes seems to work, but its settings are wrong."
        )
        XCTAssertTrue(changes.contains("[-kubenerties]"), changes)
        XCTAssertTrue(changes.contains("[+Kubernetes]"), changes)
        XCTAssertTrue(changes.contains("[-seem]"), changes)
        XCTAssertTrue(changes.contains("[+seems]"), changes)
        XCTAssertTrue(changes.contains("[+,]"))
        XCTAssertTrue(changes.contains("[+.]"))
    }

    func testEmptyRawAndLongTextRemainInspectable() {
        XCTAssertEqual(DiffUtil.diff(raw: "", cleaned: "Hello."), "[+Hello] [+.]")
        let repeated = Array(repeating: "word", count: 600).joined(separator: " ")
        let changes = DiffUtil.diff(raw: repeated, cleaned: repeated + " done")
        XCTAssertTrue(changes.contains("Original:"))
        XCTAssertTrue(changes.contains("Cleaned:"))
    }
}
