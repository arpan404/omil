import Foundation

public enum RecoveryRecordingState: String, Codable, Sendable {
    case pending
    case ready
    case failed
}

public struct RecoveryRecording: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var duration: Double
    public var filename: String
    public var state: RecoveryRecordingState
    public var transcript: String?
    public var rawTranscript: String?
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: Double,
        filename: String,
        state: RecoveryRecordingState = .pending,
        transcript: String? = nil,
        rawTranscript: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.filename = filename
        self.state = state
        self.transcript = transcript
        self.rawTranscript = rawTranscript
        self.failureReason = failureReason
    }
}

/// Bounded, app-local storage for retryable dictation audio. Metadata and WAV
/// files live together so retention cleanup cannot leave an unbounded archive.
public final class RecoveryAudioStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager
    private let metadataFilename = "recordings.json"

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            self.rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Omil/Recovery Recordings", isDirectory: true)
        }
    }

    public func load(retentionDays: Int, now: Date = Date()) -> [RecoveryRecording] {
        var recordings = readMetadata()
        recordings = prune(recordings, retentionDays: retentionDays, now: now)
        removeOrphanedAudio(keeping: Set(recordings.map(\.filename)))
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func save(
        pcm16: Data,
        sampleRate: Int = 16_000,
        createdAt: Date = Date()
    ) throws -> RecoveryRecording {
        guard !pcm16.isEmpty else {
            throw CocoaError(.fileWriteUnknown)
        }
        try createDirectory()
        let id = UUID()
        let filename = "\(id.uuidString.lowercased()).wav"
        let wav = WavEncoder().encode(pcm16: pcm16, sampleRate: sampleRate)
        let audioURL = rootURL.appendingPathComponent(filename)
        try wav.write(to: audioURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audioURL.path)

        let recording = RecoveryRecording(
            id: id,
            createdAt: createdAt,
            duration: Double(pcm16.count) / Double(sampleRate * 2),
            filename: filename
        )
        var recordings = readMetadata()
        recordings.removeAll { $0.id == id }
        recordings.append(recording)
        do {
            try writeMetadata(recordings)
        } catch {
            try? fileManager.removeItem(at: audioURL)
            throw error
        }
        return recording
    }

    public func update(_ recording: RecoveryRecording) throws {
        var recordings = readMetadata()
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
        try writeMetadata(recordings)
    }

    public func audioURL(for recording: RecoveryRecording) -> URL {
        rootURL.appendingPathComponent(recording.filename)
    }

    public func delete(_ recording: RecoveryRecording) throws {
        let audioURL = audioURL(for: recording)
        if fileManager.fileExists(atPath: audioURL.path) {
            try fileManager.removeItem(at: audioURL)
        }
        try writeMetadata(readMetadata().filter { $0.id != recording.id })
    }

    public func deleteAll() throws {
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        for recording in readMetadata() {
            let url = audioURL(for: recording)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        try writeMetadata([])
        removeOrphanedAudio(keeping: [])
    }

    @discardableResult
    public func prune(
        _ recordings: [RecoveryRecording]? = nil,
        retentionDays: Int,
        now: Date = Date()
    ) -> [RecoveryRecording] {
        let current = recordings ?? readMetadata()
        guard retentionDays > 0 else {
            for recording in current { try? deleteAudio(recording) }
            try? writeMetadata([])
            return []
        }
        guard let cutoff = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -retentionDays,
            to: now
        ) else { return current }
        let expired = current.filter { $0.createdAt < cutoff }
        let kept = current.filter { $0.createdAt >= cutoff }
        for recording in expired { try? deleteAudio(recording) }
        if kept.count != current.count { try? writeMetadata(kept) }
        return kept
    }

    private var metadataURL: URL { rootURL.appendingPathComponent(metadataFilename) }

    private func createDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
    }

    private func readMetadata() -> [RecoveryRecording] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([RecoveryRecording].self, from: data)) ?? []
    }

    private func writeMetadata(_ recordings: [RecoveryRecording]) throws {
        try createDirectory()
        let data = try JSONEncoder().encode(recordings)
        try data.write(to: metadataURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    private func deleteAudio(_ recording: RecoveryRecording) throws {
        let url = audioURL(for: recording)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func removeOrphanedAudio(keeping filenames: Set<String>) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension.lowercased() == "wav" && !filenames.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }
}
