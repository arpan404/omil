import AppKit
import Combine
import XCTest
import OmilCore
@testable import OmilMac

@MainActor
final class PillPresentationTests: XCTestCase {
    func testPillOnlyAppearsForShortcutAndMenuBarSessions() {
        XCTAssertFalse(PillManager.isEligible(source: .app, enabled: true))
        XCTAssertTrue(PillManager.isEligible(source: .shortcut, enabled: true))
        XCTAssertTrue(PillManager.isEligible(source: .menuBar, enabled: true))
        XCTAssertFalse(PillManager.isEligible(source: .shortcut, enabled: false))
        XCTAssertFalse(PillManager.isEligible(source: .menuBar, enabled: false))
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
}
