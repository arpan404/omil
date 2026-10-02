import XCTest
@testable import OmilCore

final class TranscriptDiffTests: XCTestCase {
    func testLinesSplitLikeGit() {
        let lines = TranscriptDiff.lines(
            raw: "Um, so I think we should, uh, ship it on Friday. No wait, Thursday.",
            cleaned: "I think we should ship it on Thursday."
        )
        XCTAssertTrue(lines.hasChanges)
        // The original line keeps every spoken token and marks the removed ones.
        XCTAssertEqual(lines.original.map(\.text).joined(separator: " "),
                       "Um , so I think we should , uh , ship it on Friday . No wait , Thursday .")
        XCTAssertEqual(lines.original.filter { $0.kind == .removed }.map(\.text),
                       ["Um", ",", "so", ",", "uh", ",", "Friday", ".", "No", "wait", ","])
        // The cleaned line is exactly the cleaned text, with nothing marked as removed.
        XCTAssertEqual(lines.cleaned.map(\.text).joined(separator: " "), "I think we should ship it on Thursday .")
        XCTAssertFalse(lines.cleaned.contains { $0.kind == .removed })
        XCTAssertFalse(lines.original.contains { $0.kind == .added })
    }

    func testAddedWordsOnlyAppearOnTheCleanedLine() {
        let lines = TranscriptDiff.lines(raw: "send it friday", cleaned: "Send it Friday.")
        XCTAssertEqual(lines.cleaned.filter { $0.kind == .added }.map(\.text), ["Send", "Friday", "."])
        XCTAssertEqual(lines.original.filter { $0.kind == .removed }.map(\.text), ["send", "friday"])
    }

    func testIdenticalTextHasNoChanges() {
        let lines = TranscriptDiff.lines(raw: "Ship it Thursday.", cleaned: "Ship it Thursday.")
        XCTAssertFalse(lines.hasChanges)
        XCTAssertEqual(lines.original, lines.cleaned)
    }

    func testClosingPunctuationAttaches() {
        XCTAssertTrue(TranscriptDiff.attachesToPrevious(","))
        XCTAssertTrue(TranscriptDiff.attachesToPrevious("."))
        XCTAssertFalse(TranscriptDiff.attachesToPrevious("word"))
        XCTAssertFalse(TranscriptDiff.attachesToPrevious("("))
    }
}
