import AppKit
import SwiftUI
import OmilCore

struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @State private var step = 0

    private let stepCount = 4

    var body: some View {
        ZStack {
            OmilTheme.canvas.ignoresSafeArea()
            Circle()
                .fill(OmilTheme.signal.opacity(0.13))
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: 360, y: -300)

            VStack(spacing: 0) {
                header
                Group {
                    switch step {
                    case 0: welcome
                    case 1: permissions
                    case 2: server
                    default: ready
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshMicPermission()
            Task { await controller.refreshServerHealth() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                OmilMark(size: 34, active: false)
                Text("OMIL")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(1.5)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? OmilTheme.signal : OmilTheme.lineStrong)
                        .frame(width: index == step ? 30 : 12, height: 5)
                        .animation(.easeOut(duration: 0.22), value: step)
                }
            }
            Text("\(step + 1) / \(stepCount)")
                .font(OmilType.utility(9, weight: .semibold))
                .foregroundStyle(OmilTheme.faint)
                .padding(.leading, 6)
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            Button(step == stepCount - 1 ? "Start using Omil" : "Continue") {
                if step == stepCount - 1 {
                    controller.onboarded = true
                } else {
                    step += 1
                }
            }
            .buttonStyle(SignalButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private var welcome: some View {
        HStack(spacing: 64) {
            VStack(alignment: .leading, spacing: 20) {
                Text("LOCAL DICTATION FOR MAC")
                    .font(OmilType.utility(10, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(OmilTheme.signal)
                Text("Your voice,\nready to paste.")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .tracking(-1.2)
                Text("Hold a key, speak, and release. Omil starts its own local Effect + Bun engine, then puts cleaned text at your cursor.")
                    .font(.system(size: 16))
                    .foregroundStyle(OmilTheme.muted)
                    .lineSpacing(4)
                    .frame(maxWidth: 470, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(OmilTheme.signal.opacity(0.15)).frame(width: 132, height: 132)
                    Circle().fill(OmilTheme.signal).frame(width: 86, height: 86)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 29, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("Hold. Speak. Release.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OmilTheme.muted)
            }
            .frame(width: 340, height: 330)
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(OmilTheme.line))
        }
        .padding(.horizontal, 42)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingTitle(
                eyebrow: "MAC ACCESS",
                title: "Two permissions. Both have a clear job.",
                detail: "Omil asks for nothing it does not use."
            )

            HStack(spacing: 16) {
                SetupCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Captures your speech while the shortcut is held.",
                    granted: controller.micPermission == .granted,
                    actionTitle: "Allow microphone"
                ) { controller.requestMic() }
                SetupCard(
                    icon: "cursorarrow.motionlines",
                    title: "Accessibility",
                    detail: "Inserts finished text into the field you selected.",
                    granted: controller.axTrusted,
                    actionTitle: "Allow insertion"
                ) { controller.requestAXTrust() }
            }

            Text("Without Accessibility access, Omil keeps the result ready for copy and paste.")
                .font(.system(size: 11))
                .foregroundStyle(OmilTheme.faint)
        }
        .frame(maxWidth: 760)
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingTitle(
                eyebrow: "LOCAL ENGINE",
                title: "Omil runs the server for you",
                detail: "The bundled Effect + Bun service starts with the app. Whisper and Qwen stay on this Mac."
            )

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((serverHealthy ? OmilTheme.mint : OmilTheme.signal).opacity(0.12))
                        Image(systemName: serverHealthy ? "checkmark" : "arrow.down.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(serverHealthy ? OmilTheme.mint : OmilTheme.signal)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(serverHealthy ? "Local engine ready" : "Preparing local engine")
                            .font(OmilType.display(16))
                        Text(controller.serverHealth)
                            .font(.system(size: 11))
                            .foregroundStyle(OmilTheme.muted)
                    }
                    Spacer()
                    Button("Retry") { controller.restartManagedServer() }
                        .buttonStyle(QuietButtonStyle())
                }
                .padding(14)
                .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 10))

                HStack {
                    Label("No terminal command, host, or token required", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                    Spacer()
                    Text("A remote server can be chosen later in Engine.")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.faint)
                }
            }
            .padding(18)
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(OmilTheme.line))
        }
        .frame(maxWidth: 680)
    }

    private var ready: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().fill(OmilTheme.mint.opacity(0.1)).frame(width: 112, height: 112)
                Circle().stroke(OmilTheme.mint.opacity(0.25), lineWidth: 1).frame(width: 78, height: 78)
                Image(systemName: "checkmark")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(OmilTheme.mint)
            }
            Text(serverHealthy ? "Ready to talk" : "Finishing setup")
                .font(.system(size: 40, weight: .bold, design: .rounded))
            Text("Focus a text field, hold \(HotkeyManager.shared.pushToTalkName), and speak. Release the key when you are done.")
                .font(.system(size: 15))
                .foregroundStyle(OmilTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 490)
            HStack(spacing: 10) {
                ReadyChip(icon: "server.rack", text: "Managed locally")
                ReadyChip(icon: "lock.fill", text: "Private token")
                ReadyChip(icon: "keyboard", text: HotkeyManager.shared.pushToTalkName)
            }
        }
    }

    private var serverHealthy: Bool {
        controller.serverIsReady
    }

}

private struct OnboardingTitle: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow)
                .font(OmilType.utility(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(OmilTheme.signal)
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(OmilTheme.muted)
        }
    }
}

private struct SetupCard: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(granted ? OmilTheme.mint : OmilTheme.signal)
                Spacer()
                Text(granted ? "GRANTED" : "REQUIRED")
                    .font(OmilType.utility(9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(granted ? OmilTheme.mint : OmilTheme.warning)
            }
            Text(title)
                .font(OmilType.display(18))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(OmilTheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(granted ? "Allowed" : actionTitle, action: action)
                .buttonStyle(granted ? AnyButtonStyle(QuietButtonStyle()) : AnyButtonStyle(SignalButtonStyle()))
                .disabled(granted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(granted ? OmilTheme.mint.opacity(0.2) : OmilTheme.line))
    }
}

private struct ReadyChip: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(OmilTheme.muted)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(OmilTheme.panel, in: Capsule())
            .overlay(Capsule().stroke(OmilTheme.line))
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
