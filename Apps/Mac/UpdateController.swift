import Foundation
import Sparkle

@MainActor
final class UpdateController {
    private let standardController: SPUStandardUpdaterController?

    init() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            standardController = nil
            return
        }
        standardController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var canCheckForUpdates: Bool {
        standardController?.updater.canCheckForUpdates ?? false
    }

    func checkForUpdates() {
        standardController?.checkForUpdates(nil)
    }
}

enum AppVersion {
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(version) (\(build))"
    }
}
