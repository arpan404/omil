import AppKit
import Foundation
import XCTest
import OmilCore
@testable import OmilMac

final class TextDeliveryTests: XCTestCase {
    private final class RejectingDestination: TextDestination, @unchecked Sendable {
        let identity = DestinationIdentity(appBundleId: "test.host")
        var check: DestinationCheck = .ok
        var insertionError: DeliveryError = .insertionFailed(underlying: "AXSelectedText unsupported")

        func capturePrecondition() -> SelectionPrecondition { SelectionPrecondition(rangeLocation: 0, rangeLength: 0) }
        func revalidate(precondition: SelectionPrecondition) -> DestinationCheck { check }
        func insert(text: String, precondition: SelectionPrecondition, sessionId: SessionID, sequence: Int) throws -> InsertionReceipt {
            throw insertionError
        }
    }

    func testPastesWhenDirectInsertionFailsInTheSameField() {
        let destination = RejectingDestination()
        var pastedText: String?
        let outcome = TextDelivery.attempt(
            text: "hello", precondition: destination.capturePrecondition(),
            sessionId: SessionID(), sequence: 1, destination: destination,
            trusted: true, paste: { text in pastedText = text; return .sent }
        )
        guard case .pasteSent = outcome else {
            return XCTFail("Expected a paste attempt after AX rejected direct insertion")
        }
        XCTAssertEqual(pastedText, "hello")
    }

    func testDoesNotPasteWhenDestinationChanged() {
        let destination = RejectingDestination()
        destination.check = .stale(reason: "selection moved")
        var pasteAttempted = false
        let outcome = TextDelivery.attempt(
            text: "hello", precondition: destination.capturePrecondition(),
            sessionId: SessionID(), sequence: 1, destination: destination,
            trusted: true, paste: { _ in pasteAttempted = true; return .sent }
        )
        guard case .retained = outcome else { return XCTFail("Expected the transcript to be retained") }
        XCTAssertFalse(pasteAttempted)
    }

    func testDoesNotPasteAgainAfterFieldChangesDuringInsertion() {
        let destination = RejectingDestination()
        destination.insertionError = .destinationChanged(reason: "field changed during insertion")
        var pasteAttempted = false
        let outcome = TextDelivery.attempt(
            text: "hello", precondition: destination.capturePrecondition(),
            sessionId: SessionID(), sequence: 1, destination: destination,
            trusted: true, paste: { _ in pasteAttempted = true; return .sent }
        )
        guard case .retained = outcome else { return XCTFail("Expected a retained result") }
        XCTAssertFalse(pasteAttempted)
    }

    func testPastesWhenFocusedFieldDoesNotExposeSelection() {
        let destination = RejectingDestination()
        destination.check = .pasteOnly
        var pastedText: String?
        let outcome = TextDelivery.attempt(
            text: "hello", precondition: destination.capturePrecondition(),
            sessionId: SessionID(), sequence: 1, destination: destination,
            trusted: true, paste: { text in pastedText = text; return .sent }
        )
        guard case .pasteSent = outcome else {
            return XCTFail("Expected paste into the same focused field when AX cannot read a selection")
        }
        XCTAssertEqual(pastedText, "hello")
    }

    func testDoesNotClaimACopyWhenTheClipboardCannotBePreserved() {
        let destination = RejectingDestination()
        let outcome = TextDelivery.attempt(
            text: "hello", precondition: destination.capturePrecondition(),
            sessionId: SessionID(), sequence: 1, destination: destination,
            trusted: true, paste: { _ in .unavailable }
        )
        guard case .retained(let reason) = outcome else {
            return XCTFail("Expected the transcript to stay in Omil")
        }
        XCTAssertTrue(reason.contains("clipboard"))
    }
}

final class InsertionRebaseTests: XCTestCase {
    func testThreeRecordingsCapturedAtOneCursorReplayEarlierInsertions() {
        let session = SessionID()
        let first = InsertionReceipt(
            sessionId: session, destination: DestinationIdentity(),
            precondition: SelectionPrecondition(rangeLocation: 6, rangeLength: 0),
            insertedText: "one ", commitSequence: 1, undoSupported: true
        )
        let second = InsertionReceipt(
            sessionId: session, destination: DestinationIdentity(),
            precondition: SelectionPrecondition(rangeLocation: 10, rangeLength: 0),
            insertedText: "two ", commitSequence: 2, undoSupported: true
        )
        let result = InsertionRebase.replay(
            original: "Start ", range: CFRange(location: 6, length: 0),
            receipts: [first, second]
        )
        XCTAssertEqual(result?.text, "Start one two ")
        XCTAssertEqual(result?.range.location, 14)
        XCTAssertEqual(result?.range.length, 0)
    }

    func testReplayRejectsAnUnexpectedCursorChange() {
        let receipt = InsertionReceipt(
            sessionId: SessionID(), destination: DestinationIdentity(),
            precondition: SelectionPrecondition(rangeLocation: 9, rangeLength: 0),
            insertedText: "text", commitSequence: 1, undoSupported: true
        )
        XCTAssertNil(InsertionRebase.replay(
            original: "Start ", range: CFRange(location: 6, length: 0), receipts: [receipt]
        ))
    }
}

final class ClipboardInserterTests: XCTestCase {
    func testRestoresRichClipboardContentsAfterPaste() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OmilPasteTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("test.omil.custom")
        let original = NSPasteboardItem()
        original.setString("before", forType: .string)
        original.setData(Data([1, 2, 3]), forType: customType)
        XCTAssertTrue(pasteboard.writeObjects([original]))

        let inserter = ClipboardInserter(pasteboard: pasteboard)
        guard let prepared = inserter.prepare(text: "dictated") else {
            return XCTFail("Expected existing clipboard representations to be saved")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")
        XCTAssertTrue(inserter.restoreIfOwned(prepared: prepared))
        XCTAssertEqual(pasteboard.string(forType: .string), "before")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([1, 2, 3]))
    }

    func testKeepsAUserCopyMadeAfterTheFallback() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("OmilPasteTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("before", forType: .string)
        let inserter = ClipboardInserter(pasteboard: pasteboard)
        guard let prepared = inserter.prepare(text: "dictated") else {
            return XCTFail("Expected a prepared paste")
        }
        pasteboard.clearContents()
        pasteboard.setString("new user copy", forType: .string)
        XCTAssertFalse(inserter.restoreIfOwned(prepared: prepared))
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }
}
