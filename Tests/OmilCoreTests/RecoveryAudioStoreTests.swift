import Foundation
import Testing
@testable import OmilCore

@Suite("Recovery audio storage")
struct RecoveryAudioStoreTests {
    @Test func savesUpdatesAndDeletesRecording() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omil-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryAudioStore(rootURL: root)

        var recording = try store.save(pcm16: Data(repeating: 1, count: 32_000))
        #expect(recording.duration == 1)
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))

        recording.state = .ready
        recording.transcript = "Recovered text"
        try store.update(recording)
        #expect(store.load(retentionDays: 7).first?.transcript == "Recovered text")

        try store.delete(recording)
        #expect(store.load(retentionDays: 7).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))
    }

    @Test func prunesExpiredAudioAndKeepsRecentAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omil-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryAudioStore(rootURL: root)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let old = try store.save(
            pcm16: Data(repeating: 1, count: 32),
            createdAt: now.addingTimeInterval(-8 * 86_400)
        )
        let recent = try store.save(
            pcm16: Data(repeating: 2, count: 32),
            createdAt: now.addingTimeInterval(-2 * 86_400)
        )

        let kept = store.load(retentionDays: 7, now: now)
        #expect(kept.map(\.id) == [recent.id])
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: old).path))
        #expect(FileManager.default.fileExists(atPath: store.audioURL(for: recent).path))
    }

    @Test func disabledRetentionRemovesSavedAudio() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omil-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryAudioStore(rootURL: root)
        let recording = try store.save(pcm16: Data(repeating: 1, count: 32))

        #expect(store.load(retentionDays: 0).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.audioURL(for: recording).path))
    }
}
