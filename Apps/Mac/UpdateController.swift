import Foundation
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    private var standardController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()
    private var availabilitySchedule = UpdateAvailabilitySchedule()
    private var availabilityTask: Task<Void, Never>?

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
        if startingUpdater {
            refreshAvailabilityIfNeeded()
            startAvailabilityChecks()
        }
    }

    deinit { availabilityTask?.cancel() }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        standardController?.checkForUpdates(nil)
    }

    /// Probe quietly on launch, foreground activation, and the jittered timer.
    func refreshAvailabilityIfNeeded(now: Date = Date()) {
        guard canCheckForUpdates, let updater = standardController?.updater,
              updater.automaticallyChecksForUpdates, !updater.sessionInProgress,
              availabilitySchedule.isDue(at: now) else { return }
        availabilitySchedule.recordCheck(at: now)
        updater.checkForUpdateInformation()
    }

    private var availabilityCheckDelay: TimeInterval {
        if standardController?.updater.automaticallyChecksForUpdates == true {
            // If Sparkle was busy at the deadline, retry without overlapping it.
            return max(30, availabilitySchedule.nextCheck?.timeIntervalSinceNow ?? 30)
        } else {
            return UpdateAvailabilitySchedule.randomInterval()
        }
    }

    private func startAvailabilityChecks() {
        availabilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.availabilityCheckDelay else { return }
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch { return }
                guard !Task.isCancelled else { return }
                self?.refreshAvailabilityIfNeeded()
            }
        }
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

struct UpdateAvailabilitySchedule {
    private(set) var nextCheck: Date?

    static func randomInterval() -> TimeInterval {
        .random(in: 270...330)
    }

    func isDue(at date: Date) -> Bool {
        nextCheck.map { date >= $0 } ?? true
    }

    mutating func recordCheck(at date: Date, interval: TimeInterval = randomInterval()) {
        nextCheck = date.addingTimeInterval(interval)
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(version) (\(build))"
    }
}
