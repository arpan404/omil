import AppKit
import SwiftUI
import OmilDesign
import OmilCore

/// First-run setup, modeled on Apple's Setup Assistant: one idea per page, a
/// large centered symbol, a grouped list of what matters, and pages that push
/// forward and back.
struct OnboardingView: View {
    @ObservedObject var controller: DictationController
    @State private var step: Int
    @State private var forward = true

    init(controller: DictationController, initialStep: Int = 0) {
        self.controller = controller
        _step = State(initialValue: min(max(initialStep, 0), 3))
    }

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .modifier(HidesWindowTitle())
        .onAppear {
            controller.refreshMicPermission()
            controller.refreshAXTrust()
            Task { await controller.refreshServerHealth() }
        }
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0: welcome
        case 1: permissions
        case 2: speechSetup
        default: tryIt
        }
    }

    private func go(to newStep: Int) {
        forward = newStep > step
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { step = newStep }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Back") { go(to: step - 1) }
                .buttonStyle(.plain)
                .foregroundStyle(OmilTheme.muted)
                .opacity(step > 0 ? 1 : 0)
                .disabled(step == 0 || isBusy)
                .keyboardShortcut(.leftArrow, modifiers: .command)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? OmilTheme.ink : OmilTheme.ink.opacity(0.18))
                        .frame(width: index == step ? 18 : 6, height: 6)
                }
            }
            .animation(OmilMotion.standard, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(stepCount)")

            Spacer()

            Button(primaryTitle) {
                if step == stepCount - 1 {
                    controller.onboarded = true
                } else {
                    go(to: step + 1)
                }
            }
            .omilButton(prominent: true)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(isBusy)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Get Started"
        case stepCount - 1: return "Start Using Omil"
        default: return "Continue"
        }
    }

    // MARK: Pages

    private var welcome: some View {
        SetupPage {
            OmilMark(size: 88)
                .shadow(color: .black.opacity(GlassLook.isDark ? 0.4 : 0.12), radius: 16, y: 8)
        } title: {
            "Welcome to Omil"
        } subtitle: {
            "Speak instead of typing. Omil turns your voice into clean text in whatever app you're using."
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "waveform", tint: OmilTheme.signal,
                           title: "Dictate anywhere",
                           detail: "Hold \(HotkeyManager.shared.pushToTalkName) in any text field and start talking.")
                FeatureRow(symbol: "wand.and.stars", tint: Color(hex: 0x5E5CE6),
                           title: "Clean by default",
                           detail: "Filler words and false starts are removed. Punctuation is added for you.")
                FeatureRow(symbol: "lock.fill", tint: Color(hex: 0x30B0C7),
                           title: "Private on your Mac",
                           detail: "Speech is processed on this Mac. Nothing is sent to the cloud.")
            }
            .frame(maxWidth: 420)
        }
    }

    private var permissions: some View {
        SetupPage {
            SetupSymbol(symbol: "hand.raised.fill", tint: Color(hex: 0x0A84FF))
        } title: {
            "Allow Access"
        } subtitle: {
            "Omil needs your microphone to hear you, and Accessibility to type into other apps."
        } content: {
            SetupGroup {
                PermissionRow(
                    symbol: "mic.fill",
                    tint: Color(hex: 0xFF453A),
                    title: "Microphone",
                    detail: "Used only while you dictate.",
                    granted: controller.micPermission == .granted,
                    actionTitle: controller.micPermission == .denied ? "Open Settings" : "Allow"
                ) { controller.requestMic() }
                Divider().padding(.leading, 52)
                PermissionRow(
                    symbol: "accessibility",
                    tint: Color(hex: 0x0A84FF),
                    title: "Accessibility",
                    detail: "Puts your words where your cursor is.",
                    granted: controller.axTrusted,
                    actionTitle: "Allow"
                ) { controller.requestAXTrust() }
            }
        } footnote: {
            "Without Accessibility, transcripts are still copied and shown in Omil."
        }
    }

    private var speechSetup: some View {
        SetupPage {
            SetupSymbol(symbol: "cpu.fill", tint: Color(hex: 0x636366))
        } title: {
            "Speech Models"
        } subtitle: {
            "Omil runs speech recognition and cleanup models locally on this Mac."
        } content: {
            SetupGroup {
                HStack(spacing: 12) {
                    ZStack {
                        if controller.serverIsReady {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(OmilTheme.mint)
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            ProgressView().controlSize(.small)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .animation(OmilMotion.standard, value: controller.serverIsReady)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.serverIsReady ? "Ready to transcribe" : "Preparing models…")
                            .font(.system(size: 13, weight: .medium))
                        Text(controller.speechSetupSummary)
                            .font(OmilFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    if !controller.serverIsReady {
                        Button("Retry") { controller.restartManagedServer() }
                            .omilButton()
                    }
                }
                .padding(12)
            }
        } footnote: {
            "You can choose different models any time in Engine."
        }
    }

    private var tryIt: some View {
        SetupPage {
            EmptyView()
        } title: {
            "Try It"
        } subtitle: {
            "Click the microphone and say a sentence. Click again to see your transcript."
        } content: {
            RecorderView(controller: controller, showsHeader: false)
                .frame(maxWidth: 560, minHeight: 330)
        } footnote: {
            "In other apps, hold \(HotkeyManager.shared.pushToTalkName) and speak, then release."
        }
    }

    private var isBusy: Bool {
        controller.phase == .recording || controller.phase == .preparing || controller.phase == .processing
    }
}

// MARK: - Setup building blocks

private struct SetupPage<Symbol: View, Content: View>: View {
    @ViewBuilder let symbol: () -> Symbol
    let title: () -> String
    let subtitle: () -> String
    @ViewBuilder let content: () -> Content
    var footnote: (() -> String)? = nil

    init(@ViewBuilder symbol: @escaping () -> Symbol,
         title: @escaping () -> String,
         subtitle: @escaping () -> String,
         @ViewBuilder content: @escaping () -> Content,
         footnote: (() -> String)? = nil) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.footnote = footnote
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                symbol()
                    .padding(.bottom, 20)
                Text(title())
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(OmilTheme.ink)
                    .multilineTextAlignment(.center)
                Text(subtitle())
                    .font(.system(size: 14))
                    .foregroundStyle(OmilTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 440)
                    .padding(.top, 8)
                content()
                    .padding(.top, 28)
                if let footnote {
                    Text(footnote())
                        .font(OmilFont.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }
}

/// The large tinted tile used as each page's hero symbol.
private struct SetupSymbol: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 80, height: 80)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct SetupGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(OmilTheme.groupFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 460)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(OmilTheme.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(OmilTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(OmilFont.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ZStack {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OmilTheme.mint)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    Button(actionTitle, action: action)
                        .omilButton(prominent: true)
                        .transition(.opacity)
                }
            }
            .animation(OmilMotion.standard, value: granted)
        }
        .padding(12)
    }
}

/// Setup pages show no window title, like Apple's setup assistants (macOS 15+).
private struct HidesWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}
