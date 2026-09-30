import XCTest
@testable import OmilMac

@MainActor
final class InstallationFlowTests: XCTestCase {
    func testTranslocatedLaunchRequiresInstallation() {
        let url = URL(fileURLWithPath: "/private/var/folders/test/AppTranslocation/uuid/d/Omil.app")
        XCTAssertTrue(InstallationFlow.requiresInstallation(at: url))
    }

    func testInstalledAndDevelopmentCopiesCanLaunch() {
        for path in ["/Applications/Omil.app", "/Users/test/Applications/Omil.app",
                     "/Users/test/Code/omil/.build/Omil.app"] {
            XCTAssertFalse(InstallationFlow.requiresInstallation(at: URL(fileURLWithPath: path)))
        }
    }
    func testInstallCopyDoesNotOverwriteExistingApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source.app")
        let target = root.appendingPathComponent("Omil.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = source.appendingPathComponent("payload")
        try Data("original".utf8).write(to: payload)
        try InstallationFlow.installCopy(from: source, to: target)
        try Data("replacement".utf8).write(to: payload)
        XCTAssertThrowsError(try InstallationFlow.installCopy(from: source, to: target))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("payload"), encoding: .utf8), "original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".Omil-install-") }))
    }

}
