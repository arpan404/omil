import AppKit

/// Keep first-launch setup and permissions attached to the installed app.
@MainActor
enum InstallationFlow {
    static func requiresInstallation(at url: URL = Bundle.main.bundleURL) -> Bool {
        let path = url.path
        if path.contains("/AppTranslocation/") { return true }
        guard path.hasPrefix("/Volumes/") else { return false }
        return (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    /// Returns true when normal startup must stop.
    static func handleLaunch() -> Bool {
        guard requiresInstallation() else { return false }
        let destination = URL(fileURLWithPath: "/Applications/Omil.app", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let alert = NSAlert()
        alert.messageText = exists ? "Install the new copy of Omil" : "Install Omil in Applications"
        alert.informativeText = exists
            ? "Quit your installed Omil, then drag Omil from the disk image onto Applications and choose Replace. Eject the disk image and open Omil from Applications."
            : "Omil will copy itself to Applications and open the installed copy. You can then eject the disk image and complete setup."
        alert.addButton(withTitle: exists ? "Open Applications" : "Install and Open")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }
        if exists {
            NSWorkspace.shared.open(destination.deletingLastPathComponent())
            NSApp.terminate(nil)
            return true
        }
        do {
            try installCopy(from: Bundle.main.bundleURL, to: destination)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error { showFailure(error) }
                    NSApp.terminate(nil)
                }
            }
        } catch {
            showFailure(error)
            NSApp.terminate(nil)
        }
        return true
    }

    static func installCopy(from source: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".Omil-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedApp = staging.appendingPathComponent("Omil.app", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: stagedApp)
        // Moving into place fails if another installation appeared meanwhile.
        try FileManager.default.moveItem(at: stagedApp, to: destination)
    }

    private static func showFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Finish installing in Finder"
        alert.informativeText = "\(error.localizedDescription)\n\nDrag Omil from the disk image to Applications, then open it from there."
        alert.addButton(withTitle: "Open Applications")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
    }
}
