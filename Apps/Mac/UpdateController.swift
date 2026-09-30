import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    private var standardController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private var lastAvailabilityCheck: Date?

    init(startingUpdater: Bool = true,
         publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) {
        super.init()
        guard let publicKey, Data(base64Encoded: publicKey)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        standardController = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] ready in
                guard let self else { return }
                self.canCheckForUpdates = ready
                if startingUpdater && ready { self.refreshAvailabilityIfNeeded() }
            }
            .store(in: &cancellables)
        if startingUpdater { refreshAvailabilityIfNeeded() }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        standardController?.checkForUpdates(nil)
    }

    /// Probe quietly when the app opens or returns to the foreground. Respect
    /// the user's automatic-check preference and let Sparkle schedule the rest.
    func refreshAvailabilityIfNeeded(now: Date = Date()) {
        guard canCheckForUpdates, let updater = standardController?.updater,
              updater.automaticallyChecksForUpdates, !updater.sessionInProgress,
              lastAvailabilityCheck.map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return }
        lastAvailabilityCheck = now
        updater.checkForUpdateInformation()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { availableVersion = nil }
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Scheduled discoveries appear in the sidebar and menu. Explicit
        // checks still use Sparkle's normal download/install interface.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(version) (\(build))"
    }
}
