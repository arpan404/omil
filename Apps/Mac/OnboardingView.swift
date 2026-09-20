import SwiftUI
import OmilCore

// MARK: - Onboarding (guided first run, Wispr-style)
//
// Welcome → permissions (mic + Accessibility cards) → engine setup
// (one-button prerequisites) → ready. No skipping philosophy for the
// permissions that make dictation work; every card states plainly what
// breaks without it.

struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(i <= step ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 4)
                }
            }
            .padding()

            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: engineStep
                default: readyStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if step < 3 {
                    Button("Continue") { step += 1 }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                } else {
                    Button("Start dictating") { finish() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding()
        }
        .frame(width: 560, height: 480)
        .onAppear {
            controller.refreshMicPermission()
            Task { await controller.refreshServerHealth() }
        }
    }

    func finish() {
        controller.onboarded = true
        (NSApp.delegate as? AppDelegate)?.openMainWindow()
    }

    // MARK: Steps

    var welcomeStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Welcome to Omil")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
            Text("Hold a shortcut, speak naturally, release — faithful cleaned text lands where your cursor is. Transcription and cleanup run on your Mac. No account.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }

    var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.largeTitle)
                .fontDesign(.rounded)
            PermissionCard(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Without it Omil cannot hear you and recording fails.",
                status: micStatus,
                actionLabel: micStatus == "granted" ? nil : "Allow microphone",
                action: { controller.requestMic() }
            )
            PermissionCard(
                icon: "cursorarrow.click",
                title: "Accessibility",
                detail: "Without it Omil cannot insert text into other apps and falls back to copy/paste.",
                status: controller.axTrusted ? "granted" : "not granted",
                actionLabel: controller.axTrusted ? nil : "Ask for access…",
                action: { controller.requestAXTrust() }
            )
            Text("You can change these later in Settings → Permissions.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
    }

    var micStatus: String {
        switch controller.micPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .unknown: return "not determined"
        }
    }

    var engineStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speech engine")
                .font(.largeTitle)
                .fontDesign(.rounded)
            Text("Omil transcribes with Whisper and cleans up with Qwen, served from your Mac over your LAN — never a third party.")
                .foregroundStyle(.secondary)
            OmilCard(title: "Server", icon: "network") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("In a terminal, run:")
                        .font(.callout)
                    Text("cd server && bun src/main.ts")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                    Text("First boot prints a LAN token and downloads weights on first use. Then test below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Test connection") {
                            Task { await controller.refreshServerHealth() }
                        }
                        .buttonStyle(.borderedProminent)
                        Text(controller.serverHealth)
                            .font(.callout)
                    }
                }
            }
            Spacer()
        }
        .padding()
    }

    var readyStep: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("You're ready")
                .font(.largeTitle)
                .fontDesign(.rounded)
                .fontWeight(.semibold)
            Text("Focus any text field and hold \(HotkeyManager.shared.pushToTalkName). Release to insert the cleaned result. The floating pill shows your live draft.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        }
    }
}

struct PermissionCard: View {
    var icon: String
    var title: String
    var detail: String
    var status: String
    var actionLabel: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "granted" ? .green : .orange)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let label = actionLabel {
                Button(label, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}
