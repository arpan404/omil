import XCTest
@testable import OmilCore

final class KeyboardLinkTests: XCTestCase {
    private func channel() -> LinkChannel {
        LinkChannel(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("KeyboardLinkTests-\(UUID().uuidString)"))
    }

    func testStateRoundTripsAndGoesStaleWithoutHeartbeat() {
        let link = channel()
        XCTAssertNil(link.readState())
        let now = Date()
        link.write(LinkState(phase: .recording, level: 0.4, draft: "hello", heartbeat: now), notify: false)
        let read = link.readState()
        XCTAssertEqual(read?.phase, .recording)
        XCTAssertEqual(read?.draft, "hello")
        XCTAssertTrue(read?.isLive(at: now.addingTimeInterval(1)) ?? false)
        // A suspended app stops refreshing its heartbeat.
        XCTAssertFalse(read?.isLive(at: now.addingTimeInterval(KeyboardLink.heartbeatTimeout + 1)) ?? true)
        XCTAssertFalse(LinkState(phase: .off, heartbeat: now).isLive(at: now))
    }

    func testCommandsAreHandledOnceAndExpire() {
        let link = channel()
        let now = Date()
        let start = LinkCommand(.start, issued: now)
        link.send(start)
        XCTAssertEqual(link.command(after: nil, now: now)?.kind, .start)
        XCTAssertNil(link.command(after: start.id, now: now), "the same command must not run twice")
        XCTAssertNil(link.command(after: nil, now: now.addingTimeInterval(KeyboardLink.commandTimeout + 1)),
                     "an old command left behind must be ignored")
    }

    func testKeyboardStartedResultsAreMarkedForAutoInsert() {
        let store = ResultStore()
        let fromKeyboard = store.createSession(autoInsert: true)
        store.publishResult(fromKeyboard.sessionId, cleaned: "Hi.", raw: "hi", sequence: 1)
        XCTAssertEqual(store.pendingResult()?.autoInsert, true)
        XCTAssertTrue(store.acknowledge(fromKeyboard.sessionId))
        XCTAssertFalse(store.acknowledge(fromKeyboard.sessionId))
        XCTAssertNil(store.pendingResult())
    }

    func testOlderSavedSessionsDecodeWithoutAutoInsert() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SharedSession())) as! [String: Any]
        json.removeValue(forKey: "autoInsert")
        let old = try JSONDecoder().decode(SharedSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.autoInsert)
    }
}
