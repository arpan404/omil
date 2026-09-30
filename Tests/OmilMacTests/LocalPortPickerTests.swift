import XCTest
@testable import OmilMac

final class LocalPortPickerTests: XCTestCase {
    func testUsesDefaultBlockWhenAllPortsAreFree() {
        let result = LocalPortPicker.choose(identity: "/Applications/Omil.app") { _ in true }
        XCTAssertEqual(result, LocalServerPorts(api: 3217))
        XCTAssertEqual(result?.llama, 3218)
        XCTAssertEqual(result?.whisper, 3219)
    }

    func testSkipsAnOccupiedWhisperSidecarPort() {
        let result = LocalPortPicker.choose(identity: "/Applications/Omil.app") { $0 != 3219 }
        XCTAssertNotNil(result)
        XCTAssertNotEqual(result?.api, 3217)
        XCTAssertEqual(result?.whisper, (result?.api ?? 0) + 2)
    }

    func testProbeDetectsAListeningSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 1), 0)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: actual.sin_port))
        XCTAssertFalse(LocalPortPicker.isFree(port))
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
