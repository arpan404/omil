import SwiftUI
import OmilCore
import VisionKit
import AVFoundation

@main
struct OmilIOSApp: App {
    @StateObject private var coordinator = SessionCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
        }
    }
}

struct ContentView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var resultTab = 0
    @State private var showShare = false
    @State private var showSettings = false
    @State private var showConnection = false

    private var palette: MobilePalette { MobilePalette(colorScheme) }
    private var needsServerSetup: Bool {
        coordinator.backendPreference == .omilServer &&
            (!coordinator.serverConfig.isConfigured || coordinator.serverHealth.hasPrefix("Token rejected"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    recordingPanel
                    transcriptPanel
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .background(palette.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { recordingDock }
            .toolbar(.hidden, for: .navigationBar)
            .tint(palette.signal)
            .sheet(isPresented: $showShare) {
                ShareSheet(text: coordinator.lastCleaned)
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView(coordinator: coordinator) }
            }
            .sheet(isPresented: $showConnection) {
                NavigationStack { ConnectionSettingsView(coordinator: coordinator) }
            }
            .task {
                await coordinator.refreshStatus()
                coordinator.refreshKeyboardHint()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("OMIL")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(2.5)
                    .foregroundStyle(palette.signal)
                Text("Dictate")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.ink)
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.ink)
                    .frame(width: 44, height: 44)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 13))
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.line))
            }
            .accessibilityLabel("Settings")
        }
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: needsServerSetup ? "network.slash" : coordinator.phase == .recording ? "waveform" : "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(coordinator.phase == .recording ? palette.recording : palette.signal)
                    .frame(width: 52, height: 52)
                    .background(palette.panelLifted, in: RoundedRectangle(cornerRadius: 15))
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(needsServerSetup ? palette.faint : coordinator.phase == .recording ? palette.recording : palette.mint)
                        .frame(width: 7, height: 7)
                    Text(needsServerSetup ? "SET UP MAC" : coordinator.backendPreference == .omilServer ? "YOUR MAC" : "ON DEVICE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                }
                .foregroundStyle(palette.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(phaseTitle)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.ink)
                Text(phaseDetail)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(palette.line))
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer()
                if coordinator.phase == .processing {
                    ProgressView().controlSize(.small)
                }
            }

            if !coordinator.lastCleaned.isEmpty {
                Picker("Transcript version", selection: $resultTab) {
                    Text("Clean").tag(0)
                    Text("Original").tag(1)
                    Text("Changes").tag(2)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 10) {
                if displayedText.isEmpty {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(palette.faint)
                    Text(coordinator.phase == .recording ? "Listening…" : "Your words will appear here")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.muted)
                } else {
                    Text(displayedText)
                        .font(.system(size: 16))
                        .foregroundStyle(palette.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .padding(18)
            .background(palette.panelDeep, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(palette.line))

            if !coordinator.lastCleaned.isEmpty {
                HStack(spacing: 10) {
                    resultAction("Copy", symbol: "doc.on.doc") {
                        UIPasteboard.general.string = coordinator.lastCleaned
                    }
                    resultAction("Share", symbol: "square.and.arrow.up") {
                        showShare = true
                    }
                }
                if coordinator.keyboardHint.hasPrefix("Keyboard has a result ready") {
                    Label("Ready in Omil Keyboard", systemImage: "keyboard")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                }
            }
        }
    }

    private func resultAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(palette.ink)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line))
        }
    }

    private var recordingDock: some View {
        VStack(spacing: 0) {
            Rectangle().fill(palette.line).frame(height: 1)
            HStack(spacing: 10) {
                if coordinator.phase == .recording {
                    Button { coordinator.cancel() } label: {
                        dockLabel("Cancel", symbol: "xmark")
                            .foregroundStyle(palette.ink)
                            .background(palette.panel, in: RoundedRectangle(cornerRadius: 15))
                    }
                    Button { coordinator.stop() } label: {
                        dockLabel("Done", symbol: "checkmark")
                            .foregroundStyle(palette.signalInk)
                            .background(palette.signal, in: RoundedRectangle(cornerRadius: 15))
                    }
                } else if coordinator.phase == .preparing || coordinator.phase == .processing {
                    HStack(spacing: 10) {
                        ProgressView().tint(palette.signalInk)
                        Text(coordinator.phase == .preparing ? "Getting ready…" : "Finishing…")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.signalInk)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(palette.signal.opacity(0.7), in: RoundedRectangle(cornerRadius: 15))
                } else {
                    Button {
                        if needsServerSetup { showConnection = true }
                        else { coordinator.start() }
                    } label: {
                        dockLabel(needsServerSetup ? "Connect to Mac" : "Start recording",
                                  symbol: needsServerSetup ? "network" : "mic.fill")
                            .foregroundStyle(palette.signalInk)
                            .background(palette.signal, in: RoundedRectangle(cornerRadius: 15))
                    }
                    .accessibilityHint(needsServerSetup ? "Opens connection settings" : "Starts a dictation session")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
        .background(palette.canvas)
    }

    private func dockLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .contentShape(Rectangle())
    }

    private var phaseTitle: String {
        if needsServerSetup { return "Connect your Mac" }
        switch coordinator.phase {
        case .idle, .ready: return "Ready to dictate"
        case .preparing: return "Getting ready"
        case .recording: return "Recording"
        case .processing: return "Finishing transcript"
        case .failed: return "Needs attention"
        }
    }

    private var phaseDetail: String {
        if needsServerSetup {
            return coordinator.serverHealth.hasPrefix("Token rejected")
                ? "Your saved token was rejected. Pair again with your Mac."
                : "Scan the pairing code in Omil on your Mac."
        }
        switch coordinator.phase {
        case .idle, .ready: return "Speak naturally. Omil will clean up your words."
        case .preparing: return "Connecting to your microphone."
        case .recording: return "Tap Done when you finish speaking."
        case .processing: return "Transcribing and cleaning your recording."
        case .failed: return coordinator.statusMessage
        }
    }

    private var displayedText: String {
        if coordinator.phase == .recording { return coordinator.draftText }
        switch resultTab {
        case 1: return coordinator.lastRaw
        case 2: return coordinator.lastDiff
        default: return coordinator.lastCleaned
        }
    }
}

private struct MobilePalette {
    let canvas: Color
    let panel: Color
    let panelDeep: Color
    let panelLifted: Color
    let line: Color
    let ink: Color
    let muted: Color
    let faint: Color
    let signal: Color
    let signalInk: Color
    let mint: Color
    let recording: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            canvas = Color(rgb: 0x1B1E21)
            panel = Color(rgb: 0x262B2F)
            panelDeep = Color(rgb: 0x21262A)
            panelLifted = Color(rgb: 0x323A3F)
            line = Color(rgb: 0x394248)
            ink = Color(rgb: 0xF1F4F5)
            muted = Color(rgb: 0xB5C0C5)
            faint = Color(rgb: 0x9FADB3)
            signal = Color(rgb: 0xA6D2DC)
            signalInk = Color(rgb: 0x193039)
            mint = Color(rgb: 0x72B392)
            recording = Color(rgb: 0xDB6469)
        } else {
            canvas = Color(rgb: 0xF4F5F6)
            panel = .white
            panelDeep = Color(rgb: 0xF0F2F3)
            panelLifted = Color(rgb: 0xE4E8EA)
            line = Color(rgb: 0xD8DEE1)
            ink = Color(rgb: 0x242A2E)
            muted = Color(rgb: 0x566168)
            faint = Color(rgb: 0x657077)
            signal = Color(rgb: 0x3E5D6A)
            signalInk = .white
            mint = Color(rgb: 0x287A59)
            recording = Color(rgb: 0xB8474F)
        }
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var spoken = ""
    @State private var written = ""

    private var palette: MobilePalette { MobilePalette(colorScheme) }

    var body: some View {
        Form {
            Section("Dictation") {
                Picker("Mode", selection: Binding(
                    get: { coordinator.cleanupMode },
                    set: { coordinator.setMode($0) }
                )) {
                    Text("Clean (default)").tag(CleanupMode.clean)
                    Text("Verbatim").tag(CleanupMode.verbatim)
                }
            }
            Section("Speech engine") {
                Picker("Backend", selection: $coordinator.backendPreference) {
                    Text("Omil server (your Mac)").tag(BackendChoice.omilServer)
                    Text("Automatic (on-device)").tag(BackendChoice.automatic)
                    Text("System speech").tag(BackendChoice.appleSpeech)
                    Text("Legacy on-device").tag(BackendChoice.legacySFSpeech)
                }
                .onChange(of: coordinator.backendPreference) { coordinator.saveServerConfig() }
                Text(coordinator.backendDescription).font(.caption)
                Text("Assets: \(coordinator.assetState)").font(.caption)
                Button("Refresh") {
                    Task { await coordinator.refreshStatus() }
                }
            }
            Section("Your Mac") {
                NavigationLink {
                    ConnectionSettingsView(coordinator: coordinator)
                } label: {
                    Label("Connection", systemImage: "network")
                }
                Text(coordinator.serverConfig.isConfigured ? coordinator.serverHealth : "Connect to use your Mac's speech models")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            Section("Advanced") {
                DisclosureGroup("Cleanup system prompt") {
                    Text("Sent with cleanup requests from this iPhone. The server prompt is used until you save an override.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $coordinator.cleanupPromptText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 180)
                        .accessibilityLabel("Cleanup system prompt")
                    HStack {
                        Button("Use server prompt") { coordinator.resetCleanupPrompt() }
                            .disabled(!coordinator.cleanupPromptCustom)
                        Spacer()
                        Button("Save prompt") { coordinator.saveCleanupPrompt() }
                            .disabled(coordinator.cleanupPromptText.trimmingCharacters(in: .whitespacesAndNewlines).count < 50 || coordinator.cleanupPromptText.count > 50_000)
                    }
                }
            }
            Section("Personal dictionary") {
                TextField("Spoken phrase", text: $spoken)
                TextField("Write this instead", text: $written)
                Button("Add to dictionary") {
                    guard !spoken.isEmpty, !written.isEmpty else { return }
                    coordinator.confirmDictionary(spoken: spoken, written: written)
                    spoken = ""
                    written = ""
                }
                .fontWeight(.semibold)
                ForEach(Array(coordinator.dictionaryEntries.keys.sorted()), id: \.self) { key in
                    HStack {
                        Text(key)
                        Spacer()
                        Text(coordinator.dictionaryEntries[key] ?? "").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Keyboard") {
                Text("Enable the Omil keyboard in Settings → General → Keyboard → Keyboards, then grant Full Access so it can read completed results from the shared app group.")
                    .font(.caption)
            }
            Section("Privacy") {
                Text("With the Omil server selected, audio and preferences travel only to your Mac over the local network. Omil does not require an account.")
                    .font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas.ignoresSafeArea())
        .tint(palette.signal)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await coordinator.loadCleanupPrompt() }
        .navigationTitle("Settings")
    }
}

private struct ConnectionSettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false

    private var palette: MobilePalette { MobilePalette(colorScheme) }

    var body: some View {
        Form {
            Section("Pair with your Mac") {
                Text("In Omil on your Mac, open Engine, enable sharing, and choose Pair iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(palette.muted)
                Button {
                    Task {
                        let allowed = await AVCaptureDevice.requestAccess(for: .video)
                        if allowed && DataScannerViewController.isAvailable {
                            showScanner = true
                        } else {
                            coordinator.pairingMessage = allowed
                                ? "The camera scanner is unavailable. Enter the connection details below."
                                : "Allow camera access in iPhone Settings to scan the code, or enter the details below."
                        }
                    }
                } label: {
                    Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        .fontWeight(.semibold)
                }
                .disabled(coordinator.pairingInProgress || !DataScannerViewController.isSupported)
                if !DataScannerViewController.isSupported {
                    Text("QR scanning is unavailable on this device. Enter the details below.")
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
                if !coordinator.pairingMessage.isEmpty {
                    Text(coordinator.pairingMessage)
                        .font(.caption)
                        .foregroundStyle(palette.muted)
                }
            }
            Section("Enter connection details") {
                TextField("Mac host/IP", text: $coordinator.serverConfig.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", value: $coordinator.serverConfig.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                SecureField("Token", text: $coordinator.serverConfig.token)
                Button("Save and test connection") { coordinator.saveServerConfig() }
                    .fontWeight(.semibold)
                Label(coordinator.serverHealth, systemImage: "network")
                    .font(.caption)
                    .foregroundStyle(palette.muted)
            }
            Section("Dictation") {
                Picker("Speech sensitivity", selection: $coordinator.speechSensitivity) {
                    ForEach(SpeechSensitivity.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                Text(coordinator.speechSensitivity.detail)
                    .font(.caption)
                    .foregroundStyle(palette.muted)
                Toggle("Clean up text on your Mac", isOn: Binding(
                    get: { coordinator.serverCleanupEnabled },
                    set: { coordinator.serverCleanupEnabled = $0; coordinator.saveServerConfig() }
                ))
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette.canvas.ignoresSafeArea())
        .tint(palette.signal)
        .navigationTitle("Your Mac")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                PairingScanner { code in
                    showScanner = false
                    Task { await coordinator.pair(with: code) }
                }
                .navigationTitle("Scan Mac QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Cancel") { showScanner = false }
                    }
                }
            }
        }
    }
}

private struct PairingScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        if DataScannerViewController.isAvailable {
            try? scanner.startScanning()
        }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if DataScannerViewController.isAvailable && !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var scanned = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !scanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let value = barcode.payloadStringValue {
                    scanned = true
                    dataScanner.stopScanning()
                    onScan(value)
                    return
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
