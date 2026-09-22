import AppKit
import XCTest
import OmilCore
@testable import OmilMac

@MainActor
final class RecoveryPlaybackTests: XCTestCase {
    private func withRecording(_ body: (RecoveryPlayback, UUID, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecoveryAudioStore(rootURL: root)
        let recording = try store.save(pcm16: Data(repeating: 0, count: 160_000))
        let playback = RecoveryPlayback()
        playback.volume = 0
        defer {
            playback.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await body(playback, recording.id, store.audioURL(for: recording))
    }

    func testControlsCanPrepareAndSeekBeforePlaying() async throws {
        try await withRecording { playback, id, url in
            playback.prepare(id: id, url: url)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.duration, 5, accuracy: 0.01)
            playback.seek(to: 3)
            XCTAssertEqual(playback.position, 3)
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.position, 3, accuracy: 0.1)
        }
    }

    func testPlayPauseResumeAndSeek() async throws {
        try await withRecording { playback, id, url in
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.duration, 5, accuracy: 0.01)
            playback.seek(to: 2)
            playback.toggle(id: id, url: url)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.position, 2, accuracy: 0.1)
            let pausedPosition = playback.position
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(playback.position, pausedPosition)
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(playback.position, pausedPosition, accuracy: 0.1)
            playback.seek(to: -10)
            XCTAssertEqual(playback.position, 0)
            playback.seek(to: 100)
            XCTAssertEqual(playback.position, 5)
            XCTAssertFalse(playback.isPlaying)
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertLessThan(playback.position, 0.1)
        }
    }

    func testSwitchRecordingAndStop() async throws {
        try await withRecording { playback, id, url in
            playback.toggle(id: id, url: url)
            playback.seek(to: 2)
            let nextID = UUID()
            playback.toggle(id: nextID, url: url)
            XCTAssertEqual(playback.recordingID, nextID)
            XCTAssertLessThan(playback.position, 0.1)
            XCTAssertTrue(playback.isPlaying)
            playback.stop()
            XCTAssertNil(playback.recordingID)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.position, 0)
            XCTAssertEqual(playback.duration, 0)
        }
    }

    func testCompletionAndReplay() async throws {
        try await withRecording { playback, id, url in
            playback.toggle(id: id, url: url)
            playback.seek(to: 4.9)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertFalse(playback.isPlaying)
            XCTAssertEqual(playback.position, playback.duration)
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertLessThan(playback.position, 0.1)
        }
    }

    func testMissingAudioShowsErrorAndCanRecover() async throws {
        try await withRecording { playback, id, url in
            playback.toggle(id: id, url: url.appendingPathExtension("missing"))
            XCTAssertFalse(playback.isPlaying)
            XCTAssertNotNil(playback.errorMessage)
            playback.toggle(id: id, url: url)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertNil(playback.errorMessage)
        }
    }
}
