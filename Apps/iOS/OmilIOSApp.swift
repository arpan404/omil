import SwiftUI
import OmilCore

@main
struct OmilIOSApp: App {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
                .themed()
                .modifier(AppearanceController())
        }
    }
}

/// Shows first-run setup until it's finished, then the Dictate screen.
struct RootView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @AppStorage("omil.ios.onboarded") private var onboarded = false

    var body: some View {
        Group {
            if let step = DebugLaunch.onboardingStep {
                OnboardingView(coordinator: coordinator, initialStep: step) {}
            } else if onboarded {
                DictateView(coordinator: coordinator)
                    .transition(.opacity)
            } else {
                OnboardingView(coordinator: coordinator) {
                    withAnimation(Motion.page) { onboarded = true }
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .toastHost()
        .onAppear { DebugLaunch.applyDemo(to: coordinator) }
    }
}

/// Debug-only visual QA. Launch arguments reach screens without tapping and
/// never change saved state:
///   -OmilOnboardingStep N    show setup page N (0–3)
///   -OmilScreen NAME         open History (history) or Settings: settings,
///                            appearance, dictionary, connection, engine,
///                            prompt, privacy, keyboard
///                            (keyboard focuses a text field to show the keyboard)
///   -OmilDemo NAME           fake a state: result, recording, processing,
///                            setup, notready, failed
///   -OmilDictateFile PATH    dictate a 16 kHz mono WAV through the real
///                            pipeline instead of the microphone
enum DebugLaunch {
    private static func value(_ flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
        #endif
        return nil
    }

    static var onboardingStep: Int? { value("-OmilOnboardingStep").flatMap(Int.init) }
    static var screen: String? { value("-OmilScreen") }
    static var demo: String? { value("-OmilDemo") }
    static var isDemo: Bool { demo != nil }
    static var dictateFile: String? { value("-OmilDictateFile") }

    static var settingsPath: [SettingsRoute] {
        screen.flatMap(SettingsRoute.init(rawValue:)).map { [$0] } ?? []
    }

    static var settingsAnchor: String? {
        switch screen {
        case "appearance", "dictionary": return screen
        case "keyboard": return "dictionary"
        default: return nil
        }
    }

    @MainActor
    static func applyDemo(to coordinator: SessionCoordinator) {
        #if DEBUG
        if screen == "history" { DictationHistory.shared.seedForPreview() }
        if dictateFile != nil {
            // Give the launch-time health check a moment to finish first.
            Task {
                try? await Task.sleep(for: .seconds(2))
                coordinator.start()
            }
        }
        guard let demo else { return }
        if demo != "setup" {
            let health = demo == "notready"
                ? "binaries ok · whisper downloading · cleanup model downloading"
                : "binaries ok · whisper ready · cleanup ready"
            coordinator.serverConfig = ServerConfig(host: "Studio-Mac.local", port: 3217, token: "demo")
            coordinator.serverHealth = health
            // The launch-time status probe would overwrite the fake health.
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in coordinator.serverHealth = health }
            }
        }
        let raw = "um so I think we should uh move the design review to thursday at 3 because the the prototype isn't ready yet"
        let clean = "I think we should move the design review to Thursday at 3, because the prototype isn't ready yet."
        switch demo {
        case "result":
            coordinator.lastRaw = raw
            coordinator.lastCleaned = clean
            coordinator.phase = .ready
            coordinator.keyboardResultPending = true
        case "recording":
            coordinator.phase = .recording
            coordinator.draftText = "I think we should move the design review"
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in
                    coordinator.audioLevel = Double.random(in: 0.15...0.85)
                }
            }
        case "processing":
            coordinator.phase = .processing
        case "failed":
            coordinator.phase = .failed
            coordinator.statusMessage = "Microphone permission denied."
        default:
            break
        }
        #endif
    }
}
