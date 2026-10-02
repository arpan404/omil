import SwiftUI
import UIKit
import VisionKit

/// First-run setup in the style of Apple's Setup Assistant: one idea per page,
/// a large tinted symbol, a grouped list of what matters, and pages that push
/// forward and back.
struct OnboardingView: View {
    @ObservedObject var coordinator: SessionCoordinator
    let onFinish: () -> Void
    @Environment(\.omil) private var colors
    @State private var step: Int
    @State private var forward = true
    @State private var showManualEntry = false

    private static let stepCount = 4

    init(coordinator: SessionCoordinator, initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.coordinator = coordinator
        self.onFinish = onFinish
        _step = State(initialValue: min(max(initialStep, 0), Self.stepCount - 1))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
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
        .background(colors.canvas.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: step)
        .animation(Motion.standard, value: needsPairing)
        .sheet(isPresented: $showManualEntry) {
            NavigationStack {
                ConnectionSettingsView(coordinator: coordinator, showsDone: true)
            }
            .themed()
            .toastHost()
        }
    }

    @ViewBuilder
    private func page(_ index: Int) -> some View {
        switch index {
        case 0: welcome
        case 1: connect
        case 2: keyboard
        default: done
        }
    }

    private func go(to newStep: Int) {
        forward = newStep > step
        withAnimation(Motion.page) { step = newStep }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                go(to: step - 1)
            } label: {
                Label("Back", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon)
                    .font(.body.weight(.medium))
            }
            .opacity(step > 0 ? 1 : 0)
            .disabled(step == 0)
            .accessibilityHidden(step == 0)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .animation(Motion.quick, value: step)
    }

    private var footer: some View {
        VStack(spacing: 18) {
            HStack(spacing: 7) {
                ForEach(0..<Self.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? colors.ink : colors.ink.opacity(0.18))
                        .frame(width: index == step ? 18 : 7, height: 7)
                }
            }
            .animation(Motion.standard, value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \(step + 1) of \(Self.stepCount)")

            VStack(spacing: 6) {
                if needsPairing {
                    pairingAction
                } else {
                    Button(primaryTitle) {
                        if step == Self.stepCount - 1 { onFinish() } else { go(to: step + 1) }
                    }
                    .buttonStyle(OmilButtonStyle())
                }
                // Reserve the secondary slot on every page so the dots never jump.
                Button("Set Up Later") { go(to: step + 1) }
                    .font(.body.weight(.medium))
                    .frame(minHeight: 44)
                    .opacity(needsPairing ? 1 : 0)
                    .disabled(!needsPairing)
                    .accessibilityHidden(!needsPairing)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: 520)
    }

    private var primaryTitle: String {
        switch step {
        case 0: return "Get Started"
        case Self.stepCount - 1: return "Start Dictating"
        default: return "Continue"
        }
    }

    private var needsPairing: Bool { step == 1 && !coordinator.serverConfig.isConfigured }

    @ViewBuilder
    private var pairingAction: some View {
        if DataScannerViewController.isSupported {
            ScanPairingButton(coordinator: coordinator) {
                Label(coordinator.pairingInProgress ? "Connecting…" : "Scan Pairing Code",
                      systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(OmilButtonStyle())
        } else {
            Button { showManualEntry = true } label: {
                Label("Enter Connection Details", systemImage: "keyboard")
            }
            .buttonStyle(OmilButtonStyle())
        }
    }

    // MARK: Pages

    private var welcome: some View {
        SetupPage(symbol: "waveform", tint: colors.signal, symbolInk: colors.signalInk,
                  title: "Welcome to Omil",
                  subtitle: "Speak instead of typing. Omil turns your voice into clean, ready-to-send text.") {
            SetupGroup {
                FeatureRow(symbol: "keyboard.fill", tint: .tileBlue, title: "Dictate in Any App",
                           detail: "Tap the mic on the Omil keyboard, speak, and your words appear where you're typing.")
                FeatureRow(symbol: "wand.and.stars", tint: .tileIndigo, title: "Clean by Default",
                           detail: "Filler words and false starts are removed, and punctuation is added for you.")
                FeatureRow(symbol: "lock.fill", tint: .tileTeal, title: "Free and Private on Your Mac",
                           detail: "Your Mac does the speech recognition. No cloud, no account, no subscription.")
            }
        }
    }

    private var connect: some View {
        SetupPage(symbol: "laptopcomputer.and.iphone", tint: .tileBlue,
                  title: "Connect Your Mac",
                  subtitle: "Omil on your Mac does the speech recognition. Pair once and your iPhone connects on its own.") {
            SetupGroup {
                StepRow(number: 1, text: "Open Omil on your Mac.")
                SetupDivider()
                StepRow(number: 2, text: "In Engine, turn on sharing and choose Pair iPhone.")
                SetupDivider()
                StepRow(number: 3, text: "Scan the code shown on your Mac.")
            }
            Group {
                if coordinator.serverConfig.isConfigured {
                    Label(coordinator.macConnection == .ready ? "Connected to Your Mac" : "Paired with \(coordinator.serverConfig.host)",
                          systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(colors.success)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                } else if !coordinator.pairingMessage.isEmpty {
                    Text(coordinator.pairingMessage)
                        .font(.footnote)
                        .foregroundStyle(colors.muted)
                        .multilineTextAlignment(.center)
                } else if !DataScannerViewController.isSupported {
                    Text("This device can't scan codes. Enter the details shown on your Mac instead.")
                        .font(.footnote)
                        .foregroundStyle(colors.muted)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(Motion.standard, value: coordinator.serverConfig.isConfigured)
        }
    }

    private var keyboard: some View {
        SetupPage(symbol: "keyboard.fill", tint: .tileGray,
                  title: "Turn On the Keyboard",
                  subtitle: "Dictate in any app from the Omil keyboard, then switch right back to your usual keyboard.") {
            SetupGroup {
                StepRow(number: 1, text: "Open Settings, then tap Keyboards.")
                SetupDivider()
                StepRow(number: 2, text: "Turn on Omil Dictation.")
                SetupDivider()
                StepRow(number: 3, text: "Turn on Allow Full Access so it can talk to the Omil app.")
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Settings", systemImage: "gear")
            }
            .buttonStyle(OmilButtonStyle(kind: .secondary))
        }
    }

    private var done: some View {
        SetupPage(symbol: "checkmark", tint: .tileGreen,
                  title: "You're All Set",
                  subtitle: "Here's how to dictate with Omil.") {
            SetupGroup {
                FeatureRow(symbol: "globe", tint: .tileBlue, title: "Switch to Omil",
                           detail: "In any app, tap the globe key (or touch and hold it) and choose Omil Dictation.")
                FeatureRow(symbol: "mic.fill", tint: colors.recording, title: "Tap the Mic and Speak",
                           detail: "The first time, Omil opens for a moment. Go back and keep talking.")
                FeatureRow(symbol: "checkmark.circle.fill", tint: .tileGreen, title: "Tap Done",
                           detail: "Your clean text appears where you were typing, and your usual keyboard comes back.")
            }
        }
    }
}

// MARK: - Page parts

private struct SetupPage<Content: View>: View {
    let symbol: String
    let tint: Color
    var symbolInk: Color = .white
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @Environment(\.omil) private var colors

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeroTile(symbol: symbol, color: tint, foreground: symbolInk)
                    .padding(.bottom, 24)
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(colors.ink)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                VStack(spacing: 20) {
                    content()
                }
                .padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct SetupGroup<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.omil) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupedCard(colors)
    }
}

private struct SetupDivider: View {
    var body: some View { Divider().padding(.leading, 43) }
}

private struct FeatureRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    @Environment(\.omil) private var colors
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 32

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(colors.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
