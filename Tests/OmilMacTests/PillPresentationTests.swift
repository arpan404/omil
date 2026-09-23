import AppKit
import Combine
import XCTest
import OmilCore
@testable import OmilMac

@MainActor
final class PillPresentationTests: XCTestCase {
    func testDraggedPositionSurvivesPhaseSizesAndRestart() {
        let suite = "PillPositionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var position = PillPosition(defaults: defaults)
        let dragged = NSRect(x: 410, y: 220, width: 160, height: 44)
        position.remember(dragged)
        let restored = PillPosition(defaults: defaults)
        for width in [116.0, 150, 160, 150, 150, 168, 160] {
            let frame = restored.frame(size: NSSize(width: width, height: 44), fallback: .zero,
                                       screens: [NSRect(x: 0, y: 0, width: 1200, height: 800)])
            XCTAssertEqual(frame.midX, dragged.midX)
            XCTAssertEqual(frame.minY, dragged.minY)
        }
        position.remember(NSRect(x: 600, y: 350, width: 160, height: 44))
        XCTAssertEqual(PillPosition(defaults: defaults).anchor, NSPoint(x: 680, y: 350))
    }

    func testTemporaryScreenClampingDoesNotReplaceSavedPosition() {
        let suite = "PillPositionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var position = PillPosition(defaults: defaults)
        let original = NSRect(x: 1500, y: 200, width: 160, height: 44)
        position.remember(original)
        let primary = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let secondary = NSRect(x: 1200, y: 0, width: 1200, height: 800)
        let visible = position.frame(size: original.size, fallback: .zero, screens: [primary])
        XCTAssertTrue(primary.contains(visible))
        let restored = PillPosition(defaults: defaults).frame(size: original.size, fallback: .zero,
                                                             screens: [primary, secondary])
        XCTAssertEqual(restored, original)
    }

    func testPillDisplayModes() {
        XCTAssertFalse(PillManager.isEligible(source: .app, enabled: true))
        XCTAssertTrue(PillManager.isEligible(source: .shortcut, enabled: true))
        XCTAssertTrue(PillManager.isEligible(source: .menuBar, enabled: true))
        XCTAssertTrue(PillManager.isEligible(source: .pill, enabled: true))
        XCTAssertFalse(PillManager.isEligible(source: .shortcut, enabled: false))
        XCTAssertFalse(PillManager.isEligible(source: .menuBar, enabled: false))
        XCTAssertTrue(PillManager.isEligible(source: .app, enabled: true, alwaysVisible: true))
        XCTAssertFalse(PillManager.isEligible(source: .app, enabled: false, alwaysVisible: true))
    }

    func testHiddenPillStaysHiddenUntilTheNextRecording() {
        var visibility = PillVisibility()
        visibility.observe(.preparing)
        visibility.observe(.recording)
        visibility.hide()
        XCTAssertTrue(visibility.hiddenForCurrentRecording)

        for phase in [DictationController.Phase.processing, .ready, .idle] {
            visibility.observe(phase)
            XCTAssertTrue(visibility.hiddenForCurrentRecording)
        }

        visibility.observe(.preparing)
        XCTAssertFalse(visibility.hiddenForCurrentRecording)
    }

    func testAlwaysVisiblePillReturnsAfterRecordingFinishes() {
        var visibility = PillVisibility()
        visibility.observe(.preparing, alwaysVisible: true)
        visibility.observe(.recording, alwaysVisible: true)
        visibility.hide()
        visibility.observe(.processing, alwaysVisible: true)
        XCTAssertTrue(visibility.hiddenForCurrentRecording)
        visibility.observe(.ready, alwaysVisible: true)
        XCTAssertFalse(visibility.hiddenForCurrentRecording)
    }

    func testSystemAppearanceClearsTheOverride() {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        AppAppearance.shared.apply(.light)
        XCTAssertEqual(AppAppearance.shared.colorScheme, .light)
        AppAppearance.shared.apply(.system)
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(AppAppearance.shared.colorScheme == .dark,
                       NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        AppAppearance.shared.apply(.dark)
        XCTAssertEqual(AppAppearance.shared.colorScheme, .dark)
        AppAppearance.shared.apply(.system)
        XCTAssertNil(NSApp.appearance)
        XCTAssertEqual(AppAppearance.shared.colorScheme == .dark,
                       NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    func testReleasingShortcutWhilePreparingCancelsStartup() {
        let controller = DictationController(localServer: LocalServerManager())
        controller.phase = .preparing
        controller.stop()
        XCTAssertEqual(controller.phase, .idle)
    }

    func testModelCatalogChurnDoesNotInvalidatePill() {
        let controller = DictationController(localServer: LocalServerManager())
        let presentation = PillPresentation(controller: controller)
        var invalidations = 0
        let cancellable = presentation.objectWillChange.sink { invalidations += 1 }

        controller.serverOpNote = "Downloading model"
        controller.serverModels = [
            .init(
                id: "whisper-test",
                kind: "whisper",
                description: "Test",
                filename: "test.bin",
                approxBytes: 1,
                downloaded: false,
                selected: false
            ),
        ]
        XCTAssertEqual(invalidations, 0)

        controller.phase = .processing
        XCTAssertEqual(invalidations, 1)
        XCTAssertEqual(presentation.phase, .processing)
        withExtendedLifetime(cancellable) {}
    }

    func testMenuBarIconOnlyInvalidatesWhenRecordingStateChanges() {
        let controller = DictationController(localServer: LocalServerManager())
        let state = MenuBarRecordingState(controller: controller)
        var invalidations = 0
        let cancellable = state.objectWillChange.sink { invalidations += 1 }

        controller.statusMessage = "Preparing"
        controller.phase = .preparing
        XCTAssertEqual(invalidations, 0)

        controller.phase = .recording
        XCTAssertTrue(state.isRecording)
        XCTAssertEqual(invalidations, 1)

        controller.statusMessage = "Listening"
        XCTAssertEqual(invalidations, 1)
        controller.phase = .processing
        XCTAssertFalse(state.isRecording)
        XCTAssertEqual(invalidations, 2)
        withExtendedLifetime(cancellable) {}
    }
}
