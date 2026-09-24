import Foundation
import XCTest
import OmilCore
@testable import OmilMac

final class HistoryListRowTests: XCTestCase {
    func testLargeHistoryHasStableIndividualRowsAndSearchFindsRawText() {
        let now = Date()
        let recordings = (0..<200).map { index in
            RecoveryRecording(
                createdAt: now.addingTimeInterval(Double(-index)),
                duration: 2,
                filename: "\(index).wav",
                transcript: "Recording \(index)"
            )
        }
        let history = (0..<200).map { index in
            DictationController.HistoryEntry(
                date: now.addingTimeInterval(Double(-index)),
                raw: index == 150 ? "a rare search phrase" : "raw \(index)",
                cleaned: "Transcript \(index)",
                backend: "test"
            )
        }

        let all = HistoryListRow.make(recordings: recordings, history: history, search: "")
        XCTAssertEqual(all.count, 402)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)

        let found = HistoryListRow.make(recordings: recordings, history: history, search: "rare search")
        XCTAssertEqual(found.count, 2)
        guard case .transcript(let entry) = found.last else {
            return XCTFail("Expected the matching transcript")
        }
        XCTAssertEqual(entry.raw, "a rare search phrase")
    }
}
