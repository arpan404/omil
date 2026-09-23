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
            VStack(spacing: 0) {
                header
                ScrollView {
                    Group {
                        switch step {
                        case 0: welcome
                        case 1: permissions
                        case 2: server
                        default: ready
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
            .padding(28)
        }
        .onAppear {
            controller.refreshMicPermission()
            controller.refreshAXTrust()
            Task { await controller.refreshServerHealth() }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                OmilMark(size: 34)
                Text("Omil")
                    .font(OmilType.display(17))
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
                    .disabled(isBusy)
                    .buttonStyle(QuietButtonStyle())
            }
            Spacer()
            Button(step == stepCount - 1 ? "Open Omil" : step == 0 ? "Set up Omil" : "Continue") {
                if step == stepCount - 1 {
                    controller.onboarded = true
                } else {
                    step += 1
                }
            }
            .buttonStyle(SignalButtonStyle())
            .keyboardShortcut(.return, modifiers: [])
            .disabled(isBusy)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Speak instead of typing.")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Text("Get your thoughts down as fast as you can say them. Omil turns your speech into text in the app you're using.")
                    .font(.system(size: 17))
                    .foregroundStyle(OmilTheme.muted)
                    .lineSpacing(4)
            }
            VStack(alignment: .leading, spacing: 20) {
                Label("For example, say", systemImage: "mic")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(OmilTheme.muted)
                Text("I'll send you the notes after lunch.")
                    .font(.system(size: 23, weight: .medium))
                Divider()
                Label("Your words appear where you're writing.", systemImage: "text.cursor")
                    .font(.system(size: 14))
                    .foregroundStyle(OmilTheme.muted)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OmilTheme.panel, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(OmilTheme.line))
            Label("Hold \(HotkeyManager.shared.pushToTalkName) to speak. Release to transcribe.", systemImage: "keyboard")
                .font(.system(size: 14))
                .foregroundStyle(OmilTheme.muted)
        }
        .frame(maxWidth: 600)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingTitle(
                eyebrow: "Permissions",
                title: "Let Omil hear you and write for you.",
                detail: "Allow microphone access to transcribe. Add Accessibility access to write directly in other apps."
            )

            HStack(spacing: 16) {
                SetupCard(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Records your voice when you start dictation.",
                    granted: controller.micPermission == .granted,
                    actionTitle: controller.micPermission == .denied ? "Open microphone settings" : "Allow microphone"
                ) { controller.requestMic() }
                SetupCard(
                    icon: "cursorarrow.motionlines",
                    title: "Accessibility",
                    detail: "Puts your words in the text field where you started.",
                    granted: controller.axTrusted,
                    actionTitle: "Open Accessibility settings"
                ) { controller.requestAXTrust() }
            }

            Text("You can try transcription without Accessibility access. Your text will still appear in Omil.")
                .font(.system(size: 11))
                .foregroundStyle(OmilTheme.faint)
        }
        .frame(maxWidth: 760)
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingTitle(
                eyebrow: "Speech setup",
                title: "Get ready to transcribe.",
                detail: "Omil needs speech models to turn your voice into text. You can check downloads and choose models in Engine."
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
                        Text(serverHealthy ? "Ready to transcribe" : "Checking speech setup")
                            .font(OmilType.display(16))
                        Text(controller.speechSetupSummary)
                            .font(.system(size: 11))
                            .foregroundStyle(OmilTheme.muted)
                    }
                    Spacer()
                    if !serverHealthy {
                        Button("Retry") { controller.restartManagedServer() }
                            .buttonStyle(QuietButtonStyle())
                    }
                }
                .padding(14)
                .background(OmilTheme.canvas, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 8) {
                    Label("Speech processing runs on this Mac by default", systemImage: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(OmilTheme.muted)
                    Text("Manage models in Engine.")
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
        VStack(alignment: .leading, spacing: 16) {
            OnboardingTitle(
                eyebrow: "Try dictation",
                title: "Say something. See it in writing.",
                detail: "Click the microphone, say a sentence, then stop to see your transcript."
            )
            RecorderView(controller: controller, showsHeader: false)
                .frame(minHeight: 350)
            Text("In another app, click where you want to write, hold \(HotkeyManager.shared.pushToTalkName), and speak. Release when you're done.")
                .font(.system(size: 13))
                .foregroundStyle(OmilTheme.muted)
        }
    }

    private var isBusy: Bool {
        controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing
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
                .font(.system(size: 12, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(OmilTheme.signal)
            Text(title)
                .font(.system(size: 28, weight: .semibold))
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
                Text(granted ? "Allowed" : "Not allowed")
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

private struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
