import SwiftUI
import OmilCore
import OmilDesign

// MARK: - Dictation history (on this device)

struct DictationRecord: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var date = Date()
    var raw: String
    var cleaned: String
}

/// The last 200 dictations, stored in the app's own container (never the
/// shared App Group, so the keyboard can't read past transcripts).
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    static let limit = 200

    @Published private(set) var records: [DictationRecord] = []

    private let fileURL: URL
    private let writer = DispatchQueue(label: "sh.arpan.omil.ios.history", qos: .utility)

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([DictationRecord].self, from: data) {
            records = saved
        }
    }

    func add(raw: String, cleaned: String) {
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        records = [DictationRecord(raw: raw, cleaned: cleaned)] + records.prefix(Self.limit - 1)
        save()
    }

    func delete(_ record: DictationRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Puts a deleted record back where it was (for Undo).
    func restore(_ record: DictationRecord) {
        guard !records.contains(where: { $0.id == record.id }) else { return }
        let index = records.firstIndex(where: { $0.date < record.date }) ?? records.endIndex
        records.insert(record, at: index)
        save()
    }

    func deleteAll() {
        records = []
        save()
    }

    #if DEBUG
    func seedForPreview() {
        let now = Date()
        records = [
            DictationRecord(date: now.addingTimeInterval(-120),
                            raw: "um so I think we should uh move the design review to thursday at 3",
                            cleaned: "I think we should move the design review to Thursday at 3."),
            DictationRecord(date: now.addingTimeInterval(-3_600),
                            raw: "can you send me the the slides before the call",
                            cleaned: "Can you send me the slides before the call?"),
            DictationRecord(date: now.addingTimeInterval(-90_000),
                            raw: "remind me to book flights for the offsite next month",
                            cleaned: "Remind me to book flights for the offsite next month."),
        ]
    }
    #endif

    private func save() {
        let snapshot = records
        let url = fileURL
        writer.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }
}

// MARK: - History screen

struct HistoryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @Environment(\.omil) private var colors
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [DictationRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.records }
        return history.records.filter {
            $0.cleaned.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query)
        }
    }

    private var sections: [(day: Date, records: [DictationRecord])] {
        var result: [(Date, [DictationRecord])] = []
        for record in filtered {
            let day = Calendar.current.startOfDay(for: record.date)
            if result.last?.0 == day {
                result[result.count - 1].1.append(record)
            } else {
                result.append((day, [record]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if history.records.isEmpty {
                    ContentUnavailableView {
                        Label("No Dictations Yet", systemImage: "waveform")
                            .symbolRenderingMode(.hierarchical)
                    } description: {
                        Text("Your transcripts will appear here after you dictate.")
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        ForEach(sections, id: \.day) { section in
                            Section(Self.dayTitle(section.day)) {
                                ForEach(section.records) { record in
                                    NavigationLink(value: record) {
                                        HistoryRow(record: record)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { delete(record) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button { ToastCenter.shared.copy(record.cleaned) } label: {
                                            Label("Copy", systemImage: "doc.on.doc")
                                        }
                                        .tint(colors.signal)
                                    }
                                    .contextMenu {
                                        Button("Copy", systemImage: "doc.on.doc") { ToastCenter.shared.copy(record.cleaned) }
                                        ShareLink(item: record.cleaned)
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) { delete(record) }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .animation(Motion.standard, value: filtered.map(\.id))
                }
            }
            .background(colors.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, prompt: "Search Dictations")
            .navigationDestination(for: DictationRecord.self) { record in
                HistoryDetailView(record: record)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !history.records.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("Delete All…", systemImage: "trash", role: .destructive) { confirmClear = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .confirmationDialog("Delete all dictations?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    withAnimation(Motion.standard) { history.deleteAll() }
                    ToastCenter.shared.show("History Cleared", symbol: "trash.fill")
                }
            } message: {
                Text("This removes every saved transcript from this iPhone.")
            }
        }
    }

    private func delete(_ record: DictationRecord) {
        withAnimation(Motion.standard) { history.delete(record) }
        ToastCenter.shared.show("Dictation Deleted", symbol: "trash.fill") {
            withAnimation(Motion.standard) { DictationHistory.shared.restore(record) }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    static func dayTitle(_ day: Date) -> String { dayFormatter.string(from: day) }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @Environment(\.omil) private var colors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.cleaned)
                .font(.body)
                .foregroundStyle(colors.ink)
                .lineLimit(3)
            Text(record.date, style: .time)
                .font(.footnote)
                .foregroundStyle(colors.muted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryDetailView: View {
    let record: DictationRecord
    @Environment(\.omil) private var colors
    @State private var version: TranscriptVersion = .clean

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Version", selection: $version.animation(Motion.quick)) {
                    ForEach(TranscriptVersion.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Group {
                    switch version {
                    case .clean:
                        Text(record.cleaned)
                    case .original:
                        Text(record.raw.isEmpty ? record.cleaned : record.raw)
                    case .changes:
                        GitDiffView(raw: record.raw, cleaned: record.cleaned,
                                    removed: colors.recording, added: colors.success,
                                    font: .system(.callout, design: .monospaced))
                    }
                }
                .font(.body)
                .foregroundStyle(colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(version)
                .transition(.opacity)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(colors.canvas.ignoresSafeArea())
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Copy", systemImage: "doc.on.doc") {
                    ToastCenter.shared.copy(version == .original ? record.raw : record.cleaned)
                }
                Spacer()
                ShareLink(item: version == .original ? record.raw : record.cleaned)
            }
        }
    }
}
