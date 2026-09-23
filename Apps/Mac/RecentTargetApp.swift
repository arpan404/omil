import AppKit

enum RecentTargetPolicy {
    static func preferredPID(
        source: DictationController.RecordingSource,
        frontmostPID: pid_t?,
        omilPID: pid_t,
        lastExternalPID: pid_t?
    ) -> pid_t? {
        guard let frontmostPID else { return nil }
        if frontmostPID != omilPID { return frontmostPID }
        guard source != .shortcut, let lastExternalPID, lastExternalPID != omilPID else { return nil }
        return lastExternalPID
    }
}

@MainActor
final class RecentTargetApp {
    static let shared = RecentTargetApp()

    private var lastExternalPID: pid_t?
    private var observer: NSObjectProtocol?

    private init() {
        let omilPID = NSRunningApplication.current.processIdentifier
        if let current = NSWorkspace.shared.frontmostApplication,
           current.processIdentifier != omilPID {
            lastExternalPID = current.processIdentifier
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                if pid != NSRunningApplication.current.processIdentifier {
                    self?.lastExternalPID = pid
                }
            }
        }
    }

    func target(for source: DictationController.RecordingSource) -> NSRunningApplication? {
        let pid = RecentTargetPolicy.preferredPID(
            source: source,
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            omilPID: NSRunningApplication.current.processIdentifier,
            lastExternalPID: lastExternalPID
        )
        guard let pid else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
