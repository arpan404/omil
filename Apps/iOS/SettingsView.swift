import SwiftUI
import UIKit
import OmilCore
import OmilDesign
import VisionKit

enum SettingsRoute: String, Hashable {
    case connection, engine, prompt, privacy
}

struct SettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.omil) private var colors
    @AppStorage("omil.ios.onboarded") private var onboarded = false
    @State private var path: [SettingsRoute] = DebugLaunch.settingsPath

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { scroller in
                Form {
                    dictationSection
                    macSection
                    AppearanceSection()
                        .id("appearance")
                    keyboardSection
                    DictionarySection(coordinator: coordinator)
                        .id("dictionary")
                    advancedSection
                    aboutSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(colors.canvas.ignoresSafeArea())
                .onAppear {
                    if let anchor = DebugLaunch.settingsAnchor {
                        scroller.scrollTo(anchor, anchor: .top)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .connection: ConnectionSettingsView(coordinator: coordinator)
                case .engine: EngineSettingsView(coordinator: coordinator)
                case .prompt: CleanupPromptView(coordinator: coordinator)
                case .privacy: PrivacyView()
                }
            }
            .task { await coordinator.loadCleanupPrompt() }
        }
    }

    // MARK: Sections

    private var dictationSection: some View {
        Section {
            Picker(selection: Binding(
                get: { coordinator.cleanupMode },
                set: { coordinator.setMode($0) }
            )) {
                Text("Clean").tag(CleanupMode.clean)
                Text("Verbatim").tag(CleanupMode.verbatim)
            } label: {
                Label { Text("Mode") } icon: { IconTile(symbol: "wand.and.stars", color: .tilePurple) }
            }
            Picker(selection: $coordinator.speechSensitivity) {
                ForEach(SpeechSensitivity.allCases) { Text($0.title).tag($0) }
            } label: {
                Label { Text("Sensitivity") } icon: { IconTile(symbol: "waveform", color: .tileOrange) }
            }
            Toggle(isOn: Binding(
                get: { coordinator.serverCleanupEnabled },
                set: { coordinator.serverCleanupEnabled = $0; coordinator.saveServerConfig() }
            )) {
                Label { Text("Clean Up on Your Mac") } icon: { IconTile(symbol: "sparkles", color: .tileIndigo) }
            }
            .tint(.green)
        } header: {
            Text("Dictation")
        } footer: {
            Text(modeFooter)
        }
    }

    private var modeFooter: String {
        let mode = coordinator.cleanupMode == .clean
            ? "Clean removes filler words and fixes punctuation."
            : "Verbatim keeps your words exactly as spoken."
        return "\(mode) \(coordinator.speechSensitivity.detail)"
    }

    private var macSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.connection) {
                LabeledContent {
                    Text(coordinator.macConnectionTitle)
                } label: {
                    Label { Text("Your Mac") } icon: { IconTile(symbol: "laptopcomputer", color: .tileBlue) }
                }
            }
        } header: {
            Text("Connection")
        }
    }

    private var keyboardSection: some View {
        Section {
            KeyboardSetupSteps()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                RowLabel("Open Settings", symbol: "gear", color: .tileGray)
            }
        } header: {
            Text("Keyboard")
        } footer: {
            Text("Full Access lets the keyboard read finished dictations from Omil. Nothing you type is collected.")
        }
    }

    private var advancedSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.engine) {
                Label { Text("Speech Engine") } icon: { IconTile(symbol: "cpu", color: .tileRed) }
            }
            NavigationLink(value: SettingsRoute.prompt) {
                LabeledContent {
                    Text(coordinator.cleanupPromptCustom ? "Custom" : "Default")
                } label: {
                    Label { Text("Cleanup Prompt") } icon: { IconTile(symbol: "text.quote", color: .tileTeal) }
                }
            }
        } header: {
            Text("Advanced")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.privacy) {
                Label { Text("Privacy") } icon: { IconTile(symbol: "hand.raised.fill", color: .tileBlue) }
            }
            Button {
                dismiss()
                withAnimation(Motion.page) { onboarded = false }
            } label: {
                RowLabel("Show Setup Again", symbol: "arrow.counterclockwise", color: .tileGray)
            }
            LabeledContent("Version", value: Self.version)
        } header: {
            Text("About")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// A Settings row label with a colored icon tile. Dims when its row is disabled.
struct RowLabel: View {
    let title: String
    let symbol: String
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, color: color) }
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Keyboard steps

struct KeyboardSetupSteps: View {
    var body: some View {
        StepRow(number: 1, text: "Open Settings, then tap Keyboards.")
        StepRow(number: 2, text: "Turn on Omil Dictation.")
        StepRow(number: 3, text: "Turn on Allow Full Access.")
    }
}

struct StepRow: View {
    let number: Int
    let text: String
    @Environment(\.omil) private var colors
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    var body: some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(colors.signal)
                .frame(width: size, height: size)
                .background(colors.signal.opacity(colors.isDark ? 0.2 : 0.1), in: Circle())
            Text(text)
                .foregroundStyle(colors.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

// MARK: - Appearance

struct AppearanceSection: View {
    @AppStorage(ThemeKeys.preset) private var presetRaw = ThemePreset.graphite.rawValue
    @AppStorage(ThemeKeys.appearance) private var appearanceRaw = AppearanceMode.system.rawValue

    private var preset: ThemePreset { ThemePreset.restored(from: presetRaw) ?? .graphite }
    private var mode: AppearanceMode { AppearanceMode(rawValue: appearanceRaw) ?? .system }
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Side by side normally; a list at accessibility sizes so names never break.
    private var choiceLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
    }

    var body: some View {
        Section {
            choiceLayout {
                ForEach(ThemePreset.allCases) { option in
                    ThumbnailChoice(title: option.title, subtitle: option.detail,
                                    selected: option == preset) {
                        PhoneThumbnail(light: option.palette(for: scheme))
                    } action: {
                        withAnimation(Motion.standard) { presetRaw = option.rawValue }
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Theme")

            choiceLayout {
                ForEach([AppearanceMode.light, .dark, .system]) { option in
                    ThumbnailChoice(title: option.title, subtitle: nil, selected: option == mode) {
                        switch option {
                        case .light: PhoneThumbnail(light: preset.palette(for: .light))
                        case .dark: PhoneThumbnail(light: preset.palette(for: .dark))
                        case .system: PhoneThumbnail(light: preset.palette(for: .light),
                                                     dark: preset.palette(for: .dark))
                        }
                    } action: {
                        appearanceRaw = option.rawValue
                    }
                }
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Appearance")
        } header: {
            Text("Appearance")
        }
        .sensoryFeedback(.selection, trigger: presetRaw)
        .sensoryFeedback(.selection, trigger: appearanceRaw)
    }
}

/// A choice in an appearance picker: thumbnail, a selection ring drawn inside
/// its own frame (so it never clips), and a centered label.
private struct ThumbnailChoice<Preview: View>: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    @ViewBuilder let preview: () -> Preview
    let action: () -> Void
    @Environment(\.omil) private var colors
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 16))
                : AnyLayout(VStackLayout(spacing: 8))
            layout {
                preview()
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(selected ? colors.signal : .clear, lineWidth: 2.5)
                    }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(colors.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(colors.muted)
                    }
                }
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
                .fixedSize(horizontal: false, vertical: true)
                if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        // Plain style keeps each choice its own tap target inside a Form row;
        // otherwise a tap on the row fires every button in it.
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(Motion.quick, value: selected)
    }
}

/// A tiny phone screen drawn in a palette.
private struct PhoneScreen: View {
    let colors: ThemePalette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Color(hex: colors.ink)).frame(width: 22, height: 4)
            Spacer(minLength: 0)
            Circle()
                .fill(Color(hex: colors.signal))
                .frame(width: 16, height: 16)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color(hex: colors.lineStrong)).frame(height: 3)
                Capsule().fill(Color(hex: colors.lineStrong)).frame(width: 20, height: 3)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: colors.panel), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(6)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: colors.canvas))
    }
}

private struct PhoneThumbnail: View {
    let light: ThemePalette
    var dark: ThemePalette? = nil

    var body: some View {
        ZStack {
            PhoneScreen(colors: light)
            if let dark {
                // Split diagonally, the way Settings draws Automatic.
                PhoneScreen(colors: dark)
                    .mask {
                        GeometryReader { proxy in
                            Path { path in
                                path.move(to: CGPoint(x: proxy.size.width, y: 0))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height))
                                path.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        }
        .frame(width: 58, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.black.opacity(0.14), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

// MARK: - Personal dictionary

private struct DictionarySection: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var spoken = ""
    @State private var written = ""
    @FocusState private var focus: Field?

    private enum Field { case spoken, written }

    private var canAdd: Bool {
        !spoken.trimmingCharacters(in: .whitespaces).isEmpty &&
            !written.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Section {
            TextField("When I Say", text: $spoken)
                .focused($focus, equals: .spoken)
                .submitLabel(.next)
                .onSubmit { focus = .written }
                .textInputAutocapitalization(.never)
            TextField("Write", text: $written)
                .focused($focus, equals: .written)
                .submitLabel(.done)
                .onSubmit(add)
            Button(action: add) {
                RowLabel("Add Word", symbol: "plus", color: .tileGreen)
            }
            .disabled(!canAdd)

            ForEach(coordinator.dictionaryEntries.keys.sorted(), id: \.self) { key in
                LabeledContent(key, value: coordinator.dictionaryEntries[key] ?? "")
                    .swipeActions {
                        Button(role: .destructive) { remove(key) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        } header: {
            Text("Personal Dictionary")
        } footer: {
            Text("Omil writes these words your way. Swipe left on a word to delete it.")
        }
        .onAppear {
            if DebugLaunch.screen == "keyboard" { focus = .spoken }
        }
    }

    private func add() {
        guard canAdd else { return }
        let key = spoken.trimmingCharacters(in: .whitespaces)
        withAnimation(Motion.standard) {
            coordinator.confirmDictionary(spoken: key, written: written.trimmingCharacters(in: .whitespaces))
        }
        spoken = ""
        written = ""
        focus = nil
        ToastCenter.shared.show("Added “\(key)”", symbol: "character.book.closed.fill") { [coordinator] in
            withAnimation(Motion.standard) { coordinator.removeDictionary(spoken: key) }
        }
    }

    private func remove(_ key: String) {
        let value = coordinator.dictionaryEntries[key] ?? ""
        withAnimation(Motion.standard) { coordinator.removeDictionary(spoken: key) }
        ToastCenter.shared.show("Deleted “\(key)”", symbol: "trash.fill") { [coordinator] in
            withAnimation(Motion.standard) { coordinator.confirmDictionary(spoken: key, written: value) }
        }
    }
}

// MARK: - Your Mac

struct ConnectionSettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    var showsDone = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.omil) private var colors
    @State private var host = ""
    @State private var port = 3217
    @State private var token = ""

    private var connected: Bool { coordinator.macConnection == .ready }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    HeroTile(symbol: connected ? "checkmark" : "laptopcomputer.and.iphone",
                             color: connected ? colors.success : colors.signal,
                             foreground: connected ? .white : colors.signalInk)
                        .contentTransition(.symbolEffect(.replace))
                    Text(coordinator.macConnectionTitle)
                        .font(.title3.bold())
                        .foregroundStyle(colors.ink)
                        .contentTransition(.opacity)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(colors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .animation(Motion.standard, value: coordinator.macConnection)
            }

            Section {
                ScanPairingButton(coordinator: coordinator) {
                    RowLabel(coordinator.pairingInProgress ? "Connecting…" : "Scan Pairing Code",
                             symbol: "qrcode.viewfinder", color: .tileBlue)
                }
                if !DataScannerViewController.isSupported {
                    Text("This device can't scan codes. Enter the details below instead.")
                        .font(.footnote)
                        .foregroundStyle(colors.muted)
                } else if !coordinator.pairingMessage.isEmpty {
                    Text(coordinator.pairingMessage)
                        .font(.footnote)
                        .foregroundStyle(colors.muted)
                }
            } header: {
                Text("Pair With Your Mac")
            } footer: {
                Text("In Omil on your Mac, open Engine, turn on sharing, and choose Pair iPhone.")
            }

            Section {
                LabeledContent("Host") {
                    TextField("Mac name or IP address", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Port") {
                    TextField("3217", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField("Pairing token", text: $token)
                        .multilineTextAlignment(.trailing)
                }
                Button("Save and Test Connection", action: save)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Connection Details")
            } footer: {
                Text("Use these if you can't scan the code.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(colors.canvas.ignoresSafeArea())
        .navigationTitle("Your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: coordinator.serverConfig) { loadFields() }
        .onChange(of: coordinator.macConnection) { old, new in
            guard old != new, old == .checking else { return }
            if new == .ready {
                ToastCenter.shared.show("Connected to Your Mac")
            } else if new != .checking {
                ToastCenter.shared.show(coordinator.macConnectionTitle, symbol: "exclamationmark.triangle.fill", tone: .warning)
            }
        }
    }

    private var statusDetail: String {
        switch coordinator.macConnection {
        case .notConfigured: return "Pair this iPhone with Omil on your Mac to dictate."
        case .tokenRejected: return "Your Mac no longer accepts this iPhone. Scan a new code."
        case .checking: return "Checking the connection…"
        case .ready: return "Speech runs on \(coordinator.serverConfig.host)."
        case .preparing: return "Your Mac is still downloading its speech models."
        case .needsAttention: return "Open Omil on your Mac to finish setting up the engine."
        case .unreachable: return "Keep Omil open on your Mac and both devices on the same network."
        }
    }

    private func loadFields() {
        host = coordinator.serverConfig.host
        port = coordinator.serverConfig.port
        token = coordinator.serverConfig.token
    }

    private func save() {
        coordinator.serverConfig.host = host.trimmingCharacters(in: .whitespaces)
        coordinator.serverConfig.port = port
        coordinator.serverConfig.token = token.trimmingCharacters(in: .whitespaces)
        coordinator.saveServerConfig()
    }
}

// MARK: - Advanced

struct EngineSettingsView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors
    @State private var refreshing = false

    var body: some View {
        Form {
            Section {
                Picker("Speech Engine", selection: $coordinator.backendPreference) {
                    Text("Your Mac").tag(BackendChoice.omilServer)
                    Text("Automatic (On Device)").tag(BackendChoice.automatic)
                    Text("Apple Speech").tag(BackendChoice.appleSpeech)
                    Text("Legacy On Device").tag(BackendChoice.legacySFSpeech)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: coordinator.backendPreference) {
                    coordinator.saveServerConfig()
                    refresh()
                }
            } footer: {
                Text("Your Mac gives the best accuracy and cleanup. On-device engines work offline with simpler cleanup.")
            }
            Section {
                LabeledContent("Engine", value: coordinator.backendDescription)
                LabeledContent("Status", value: coordinator.assetState)
                Button(action: refresh) {
                    HStack {
                        Text("Refresh Status")
                        Spacer()
                        if refreshing { ProgressView() }
                    }
                }
                .disabled(refreshing)
            } header: {
                Text("Diagnostics")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(colors.canvas.ignoresSafeArea())
        .navigationTitle("Speech Engine")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refresh() {
        refreshing = true
        Task {
            await coordinator.refreshStatus()
            refreshing = false
        }
    }
}

/// Edits a local draft so typing doesn't republish through the coordinator on
/// every keystroke; the draft is written back on Save.
struct CleanupPromptView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @Environment(\.omil) private var colors
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var draftIsValid: Bool {
        draft.count <= 50_000 && draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50
    }

    private var hasChanges: Bool {
        draft != coordinator.cleanupPromptText || !coordinator.cleanupPromptCustom
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft)
                    .font(.footnote.monospaced())
                    .frame(minHeight: 260)
                    .focused($editing)
                    .accessibilityLabel("Cleanup prompt")
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty && !editing {
                            Text("Connect to your Mac to load its prompt, or write your own. Prompts need at least 50 characters.")
                                .font(.footnote)
                                .foregroundStyle(colors.faint)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                Text(coordinator.cleanupPromptCustom ? "Your Prompt" : "Your Mac's Prompt")
            } footer: {
                Text("Guides how your Mac cleans up dictation from this iPhone. Protected values and word checks still apply.")
            }
            Section {
                Button("Use Mac's Prompt", role: .destructive) {
                    coordinator.resetCleanupPrompt()
                    ToastCenter.shared.show("Using Your Mac's Prompt", symbol: "arrow.uturn.backward.circle.fill")
                }
                .disabled(!coordinator.cleanupPromptCustom)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(colors.canvas.ignoresSafeArea())
        .navigationTitle("Cleanup Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    coordinator.cleanupPromptText = draft
                    coordinator.saveCleanupPrompt()
                    editing = false
                    ToastCenter.shared.show("Prompt Saved")
                }
                .disabled(!draftIsValid || !hasChanges)
            }
        }
        .onAppear { draft = coordinator.cleanupPromptText }
        .onChange(of: coordinator.cleanupPromptText) { _, text in
            if !editing { draft = text }
        }
        .task { await coordinator.loadCleanupPrompt() }
    }
}

struct PrivacyView: View {
    @Environment(\.omil) private var colors

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    HeroTile(symbol: "hand.raised.fill", color: .tileBlue)
                    Text("Your Words Stay Yours")
                        .font(.title3.bold())
                        .foregroundStyle(colors.ink)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                PrivacyRow(symbol: "laptopcomputer", title: "Processed on Your Mac",
                           detail: "Audio travels only to your Mac over your local network.")
                PrivacyRow(symbol: "person.crop.circle.badge.xmark", title: "No Account",
                           detail: "Omil doesn't need an account and has no cloud service.")
                PrivacyRow(symbol: "keyboard", title: "Keyboard Reads Only Omil",
                           detail: "The keyboard reads finished dictations from Omil. It doesn't record what you type.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(colors.canvas.ignoresSafeArea())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Environment(\.omil) private var colors
    @ScaledMetric(relativeTo: .title3) private var iconWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(colors.signal)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(colors.ink)
                Text(detail).font(.subheadline).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
