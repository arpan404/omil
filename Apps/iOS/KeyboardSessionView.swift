import SwiftUI
import OmilCore

/// Shown when the Omil keyboard opens the app to dictate. Omil is already
/// listening; this screen says so and points at the system's back button, so
/// the user returns to their app and keeps talking there.
struct ReturnToAppView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors
    @State private var levels = [Double](repeating: 0, count: Waveform.barCount)
    @State private var recordingStart: Date?
    @State private var nudge = false

    private var phase: SessionCoordinator.Phase { coordinator.phase }

    var body: some View {
        VStack(spacing: 0) {
            backHint
            Spacer(minLength: 24)
            center
            Spacer(minLength: 24)
            controls
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.canvas.ignoresSafeArea())
        .animation(Motion.standard, value: phase)
        .onAppear { if phase == .recording { recordingStart = .now } }
        .onChange(of: phase) { _, new in
            recordingStart = new == .recording ? .now : nil
            if new == .recording { levels = [Double](repeating: 0, count: Waveform.barCount) }
        }
        .onChange(of: coordinator.audioLevel) { _, level in
            guard phase == .recording else { return }
            levels.removeFirst()
            levels.append(level)
        }
        .sensoryFeedback(trigger: phase) { _, new in
            switch new {
            case .recording: return .impact(weight: .medium)
            case .ready: return .success
            case .failed: return .error
            default: return nil
            }
        }
    }

    /// Points at the "◀ App" breadcrumb iOS shows in the top-left corner.
    private var backHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.up.left")
                .font(.title3.weight(.semibold))
                .offset(x: nudge ? -4 : 0, y: nudge ? -4 : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: nudge)
                .onAppear { nudge = true }
            Text("Tap here to go back")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)
            Spacer()
        }
        .foregroundStyle(colors.signal)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Use the back button in the top-left corner to return to your app.")
    }

    @ViewBuilder
    private var center: some View {
        VStack(spacing: 18) {
            switch phase {
            case .preparing, .recording:
                ListeningBadge(active: phase == .recording)
                Waveform(levels: levels, color: colors.recording)
                    .scaleEffect(1.4)
                    .frame(height: 60)
                if let recordingStart {
                    ElapsedTime(start: recordingStart)
                }
                title("Go back and keep talking")
                detail("Omil is listening. When you finish, tap Done on the Omil keyboard and your words appear where you were typing.")
            case .processing:
                ProgressView().controlSize(.large)
                title("Transcribing")
                detail("Go back to your app. The text goes in as soon as your Mac finishes.")
            case .idle, .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(colors.success)
                title("Ready in Your App")
                detail("Go back to your app. Your text goes in where you were typing, and the next dictation starts right from the keyboard.")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(colors.warning)
                title("Dictation Didn't Start")
                detail(coordinator.statusMessage)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(colors.ink)
            .multilineTextAlignment(.center)
            .contentTransition(.opacity)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(colors.muted)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            switch phase {
            case .recording:
                Button { coordinator.stop() } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(OmilButtonStyle())
                Button("Cancel", role: .cancel) { coordinator.cancel() }
                    .buttonStyle(OmilButtonStyle(kind: .secondary))
            case .failed:
                Button { coordinator.start(origin: .keyboard) } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(OmilButtonStyle())
                Button("Close") { coordinator.showsReturnHint = false }
                    .buttonStyle(OmilButtonStyle(kind: .secondary))
            default:
                Button("Stay in Omil") { coordinator.showsReturnHint = false }
                    .buttonStyle(OmilButtonStyle(kind: .secondary))
            }
            MicSessionFootnote(coordinator: coordinator)
                .padding(.top, 2)
        }
    }
}

/// "Mic ready for 4:12 · Turn Off": the keyboard's mic session, in plain words.
struct MicSessionFootnote: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors

    var body: some View {
        if let ends = coordinator.micSessionEnds {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(colors.recording)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Keyboard mic ready for \(Self.remaining(until: ends, now: context.date))")
                        .monospacedDigit()
                }
                .foregroundStyle(colors.muted)
                Text("·").foregroundStyle(colors.faint)
                Button("Turn Off") { coordinator.endMicSession() }
                    .fontWeight(.semibold)
            }
            .font(.footnote)
            .accessibilityElement(children: .contain)
        }
    }

    static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// The Dictate screen's reminder that the microphone stays on for the keyboard.
struct MicSessionBanner: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors

    var body: some View {
        if let ends = coordinator.micSessionEnds {
            HStack(spacing: 12) {
                Image(systemName: "mic.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(colors.recording)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard Mic Is On")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(colors.ink)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("Dictate from the Omil keyboard in any app. Turns off in \(MicSessionFootnote.remaining(until: ends, now: context.date)).")
                            .monospacedDigit()
                    }
                    .font(.footnote)
                    .foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Turn Off") { coordinator.endMicSession() }
                    .buttonStyle(OmilButtonStyle(kind: .secondary, fullWidth: false))
                    .controlSize(.small)
            }
            .padding(14)
            .groupedCard(colors)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ListeningBadge: View {
    let active: Bool
    @Environment(\.omil) private var colors

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill")
                .font(.caption2)
                .imageScale(.small)
                .foregroundStyle(active ? colors.recording : colors.faint)
                .symbolEffect(.pulse, options: .repeating, isActive: active)
            Text(active ? "Listening" : "Starting")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.ink)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .background(colors.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(colors.line, lineWidth: 0.5))
    }
}
