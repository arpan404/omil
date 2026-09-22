import AppKit
import XCTest
import OmilCore
@testable import OmilMac

@MainActor
final class HotkeyManagerTests: XCTestCase {
    func testCombinationReleasesOnceAndIgnoresRepeats() {
        let suite = "omil-hotkey-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkeys = HotkeyManager(defaults: defaults)
        XCTAssertTrue(hotkeys.setPushToTalk(keyCode: 49, modifiers: [.control, .shift], character: " "))
        var starts = 0
        var stops = 0
        hotkeys.onPushStart = { starts += 1 }
        hotkeys.onPushStop = { stops += 1 }
        XCTAssertFalse(hotkeys.handleKeyDown(keyCode: 49, flags: [.control]))
        XCTAssertTrue(hotkeys.handleKeyDown(keyCode: 49, flags: [.control, .shift]))
        hotkeys.handleKeyDown(keyCode: 49, flags: [.control, .shift], isRepeat: true)
        XCTAssertEqual(starts, 1)
        hotkeys.handleFlags(keyCode: 56, flags: [.control])
        hotkeys.handleKeyUp(keyCode: 49)
        XCTAssertEqual(stops, 1)
        hotkeys.handleKeyDown(keyCode: 49, flags: [.control, .shift])
        hotkeys.handleKeyUp(keyCode: 49)
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(stops, 2)
        let restored = HotkeyManager(defaults: defaults)
        XCTAssertEqual(restored.pushToTalkName, "⌃⇧Space")
        XCTAssertEqual(restored.pushToTalkModifiers, [.control, .shift])
        XCTAssertFalse(restored.setPushToTalk(keyCode: 31, modifiers: [.control, .option], character: "o"))
        XCTAssertFalse(restored.setPushToTalk(keyCode: 0, character: "a"))
    }

    func testCaptureSuspendsShortcutsAndToggleIgnoresRepeat() {
        let suite = "omil-hotkey-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkeys = HotkeyManager(defaults: defaults)
        var starts = 0
        var toggles = 0
        hotkeys.onPushStart = { starts += 1 }
        hotkeys.onToggle = { toggles += 1 }
        hotkeys.capturingShortcut = true
        hotkeys.handleFlags(keyCode: 61, flags: [.option])
        hotkeys.handleKeyDown(keyCode: 31, flags: [.control, .option])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(toggles, 0)
        hotkeys.capturingShortcut = false
        hotkeys.handleKeyDown(keyCode: 31, flags: [.control, .option])
        hotkeys.handleKeyDown(keyCode: 31, flags: [.control, .option], isRepeat: true)
        XCTAssertEqual(toggles, 1)
        XCTAssertFalse(hotkeys.handleKeyDown(keyCode: 53, flags: []))
    }

    func testEveryModifierStartsAndStopsPushToTalk() {
        let suite = "omil-hotkey-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hotkeys = HotkeyManager(defaults: defaults)
        for (code, flag): (Int, NSEvent.ModifierFlags) in [
            (61, .option), (58, .option), (59, .control), (62, .control),
            (55, .command), (54, .command), (56, .shift), (60, .shift), (63, .function)
        ] {
            var starts = 0
            var stops = 0
            hotkeys.onPushStart = { starts += 1 }
            hotkeys.onPushStop = { stops += 1 }
            hotkeys.setPushToTalk(keyCode: code)
            hotkeys.handleFlags(keyCode: UInt16(code), flags: flag)
            hotkeys.handleFlags(keyCode: UInt16(code), flags: [])
            XCTAssertEqual(starts, 1, "Modifier \(code) should start recording")
            XCTAssertEqual(stops, 1, "Modifier \(code) should stop recording")
        }
    }
}
