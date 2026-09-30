import Foundation
import XCTest
import OmilCore
@testable import OmilMac

final class HistoryFeedTests: XCTestCase {
    private func entries(count: Int) -> [DictationController.HistoryEntry] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { i in
            DictationController.HistoryEntry(date: now.addingTimeInterval(Double(-i) * 86_400),
                raw: i == count - 1 ? "needle in older raw text" : "raw", cleaned: "Transcript \(i)", backend: "test")
        }
    }

    func testPagesCoverEveryItemOnceWithoutDanglingHeaders() {
        let history = entries(count: 61)
        let recordings = (0..<9).map {
            RecoveryRecording(duration: 1, filename: "\($0).wav", transcript: "audio")
        }
        let index = HistoryFeedIndex(recordings: recordings, history: history, search: "")
        var offset = 0
        var rows: [HistoryListRow] = []
        while offset < index.rows.count {
            let page = index.page(after: offset)
            XCTAssertLessThanOrEqual(page.itemCount, 25)
            XCTAssertGreaterThan(page.itemCount, 0)
            switch page.rows.last {
            case .dayHeader, .savedHeader: XCTFail("A page must end on an item")
            default: break
            }
            rows += page.rows
            offset = page.nextOffset
        }
        XCTAssertEqual(index.itemCount, 70)
        XCTAssertEqual(rows.map(\.id), index.rows.map(\.id))
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testSearchFindsRawTextBeyondFirstPage() {
        let index = HistoryFeedIndex(recordings: [], history: entries(count: 200), search: "needle")
        XCTAssertEqual(index.itemCount, 1)
        XCTAssertEqual(index.page().itemCount, 1)
    }

    func testPreviewIsBoundedAndFullTranscriptIsPreserved() {
        let full = String(repeating: "long transcript ", count: 10_000)
        let entry = DictationController.HistoryEntry(raw: full, cleaned: full, backend: "test")
        let page = HistoryFeedIndex(recordings: [], history: [entry], search: "").page()
        let display = page.display["transcript-\(entry.id)"]!
        XCTAssertEqual(display.preview.count, 601)
        XCTAssertTrue(display.preview.hasSuffix("…"))
        XCTAssertEqual(display.wordCount, 20_000)
        guard case .transcript(let retained) = page.rows.last else { return XCTFail("Missing transcript") }
        XCTAssertEqual(retained.cleaned, full)
    }

    @MainActor
    func testFeedLoadsOnePageThenAppendsAndResetsForSearch() async {
        let feed = HistoryFeed()
        let history = entries(count: 70)
        await feed.reload(recordings: [], history: history, search: "")
        XCTAssertEqual(feed.loadedCount, 25)
        XCTAssertTrue(feed.hasMore)
        await feed.loadMore()
        XCTAssertEqual(feed.loadedCount, 50)
        await feed.reload(recordings: [], history: history, search: "", preserveLoadedCount: true)
        XCTAssertEqual(feed.loadedCount, 50)
        await feed.reload(recordings: [], history: history, search: "needle")
        XCTAssertEqual(feed.loadedCount, 1)
        XCTAssertFalse(feed.hasMore)
    }
    @MainActor
    func testCancelledLoadDoesNotPublishIncompleteResults() async {
        let feed = HistoryFeed()
        let history = entries(count: 200)
        let load = Task { await feed.reload(recordings: [], history: history, search: "") }
        load.cancel()
        await load.value
        XCTAssertFalse(feed.hasLoaded)
        XCTAssertTrue(feed.rows.isEmpty)
        XCTAssertFalse(feed.isLoading)
    }

}
