import Foundation
import Combine
import OmilCore

enum HistoryListRow: Identifiable, Sendable {
    case savedHeader
    case recording(RecoveryRecording)
    case dayHeader(Date)
    case transcript(DictationController.HistoryEntry)

    var id: String {
        switch self {
        case .savedHeader: return "saved-header"
        case .recording(let recording): return "recording-\(recording.id)"
        case .dayHeader(let day): return "day-\(day.timeIntervalSinceReferenceDate)"
        case .transcript(let entry): return "transcript-\(entry.id)"
        }
    }

    static func make(
        recordings: [RecoveryRecording],
        history: [DictationController.HistoryEntry],
        search: String
    ) -> [HistoryListRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = {
            !Task.isCancelled && (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }
        var rows: [HistoryListRow] = []
        let matchingRecordings = recordings.filter {
            matches($0.transcript ?? "") || matches($0.rawTranscript ?? "")
        }
        if !matchingRecordings.isEmpty {
            rows.append(.savedHeader)
            rows.append(contentsOf: matchingRecordings.map(HistoryListRow.recording))
        }
        var lastDay: Date?
        for entry in history.sorted(by: { $0.date > $1.date }) where matches(entry.cleaned) || matches(entry.raw) {
            let day = Calendar.current.startOfDay(for: entry.date)
            if lastDay != day {
                rows.append(.dayHeader(day))
                lastDay = day
            }
            rows.append(.transcript(entry))
        }
        return rows
    }
}

/// A full search index of value types. Only a page is projected into UI rows.
struct HistoryFeedIndex: Sendable {
    struct Display: Sendable {
        let preview: String
        let wordCount: Int?
    }

    struct Page: Sendable {
        let rows: [HistoryListRow]
        let display: [String: Display]
        let nextOffset: Int
        let itemCount: Int
    }

    let rows: [HistoryListRow]
    let itemCount: Int

    init(recordings: [RecoveryRecording], history: [DictationController.HistoryEntry], search: String) {
        rows = HistoryListRow.make(recordings: recordings, history: history, search: search)
        itemCount = rows.reduce(0) { count, row in
            switch row {
            case .recording, .transcript: return count + 1
            default: return count
            }
        }
    }

    func page(after offset: Int = 0, limit: Int = 25) -> Page {
        var end = min(max(0, offset), rows.count)
        let start = end
        var count = 0
        var display: [String: Display] = [:]
        while end < rows.count && count < max(1, limit) {
            let row = rows[end]
            switch row {
            case .transcript(let entry):
                display[row.id] = Display(preview: Self.preview(entry.cleaned), wordCount: entry.wordCount)
                count += 1
            case .recording(let recording):
                display[row.id] = Display(preview: Self.preview(recording.transcript ?? ""), wordCount: nil)
                count += 1
            case .dayHeader, .savedHeader: break
            }
            end += 1
        }
        return Page(rows: Array(rows[start..<end]), display: display, nextOffset: end, itemCount: count)
    }

    /// A two-line list should never shape an entire long transcript.
    static func preview(_ text: String) -> String {
        let prefix = text.prefix(601)
        return prefix.count > 600 ? String(prefix.prefix(600)) + "…" : String(prefix)
    }
}

@MainActor
final class HistoryFeed: ObservableObject {
    nonisolated static let pageSize = 25
    @Published private(set) var rows: [HistoryListRow] = []
    @Published private(set) var display: [String: HistoryFeedIndex.Display] = [:]
    @Published private(set) var totalCount = 0
    @Published private(set) var loadedCount = 0
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false

    private var index: HistoryFeedIndex?
    private var offset = 0
    private var generation = 0
    var hasMore: Bool { offset < (index?.rows.count ?? 0) }

    func reload(recordings: [RecoveryRecording], history: [DictationController.HistoryEntry],
                search: String, preserveLoadedCount: Bool = false) async {
        generation += 1
        let request = generation
        let limit = preserveLoadedCount ? max(Self.pageSize, loadedCount) : Self.pageSize
        isLoading = true
        isLoadingMore = false
        defer { if generation == request { isLoading = false } }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let index = HistoryFeedIndex(recordings: recordings, history: history, search: search)
            let page = index.page(limit: limit)
            try Task.checkCancellation()
            return (index, page)
        }
        let result = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, generation == request, let (index, page) = result else { return }
        self.index = index
        totalCount = index.itemCount
        rows = page.rows
        display = page.display
        loadedCount = page.itemCount
        offset = page.nextOffset
        hasLoaded = true
    }

    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasMore, let index else { return }
        let request = generation
        let start = offset
        isLoadingMore = true
        defer { if generation == request { isLoadingMore = false } }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let page = index.page(after: start, limit: Self.pageSize)
            try Task.checkCancellation()
            return page
        }
        let page = await withTaskCancellationHandler {
            try? await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, generation == request, let page else { return }
        rows.append(contentsOf: page.rows)
        display.merge(page.display) { _, new in new }
        loadedCount += page.itemCount
        offset = page.nextOffset
    }
}
