import Foundation
#if canImport(Speech)
import Speech
#endif

// MARK: - ServerTranscriptionBackend (Whisper large via Omil server)
//
// Buffers streamed PCM and uploads one WAV at finalization — Whisper is a
// batch model, so this backend offers no volatile partials. The UI shows a
// level/elapsed indicator instead of a draft transcript in this mode.

public struct ServerSegment: Codable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

public struct ServerTranscript: Codable, Sendable {
    public var text: String
    public var segments: [ServerSegment]
    public var model: String
}

public actor ServerTranscriptionBackend: TranscriptionBackend {
    public nonisolated let identity: BackendIdentity = .server
    public nonisolated let capabilities = BackendCapabilities(
        supportsStreaming: true, supportsPartials: false, supportsTimestamps: true,
        supportsAlternatives: false, requiresAssetDownload: true)
    public nonisolated let requiredAudioFormat = AudioFormatRequirements(
        sampleRate: 16_000, channelCount: 1, description: "16kHz mono PCM16 WAV upload")
    public nonisolated let locale: String

    private let config: ServerConfig
    private let modelId: String?
    private var pcm = Data()
    private var sampleRate = 16_000.0
    private var events: AsyncStream<BackendEvent>.Continuation?
    private var finished = false
    private var requestId: String?

    public init(config: ServerConfig, locale: String = "en-US", modelId: String? = nil) {
        self.config = config
        self.locale = locale
        self.modelId = modelId
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard let endpoint = config.endpoint(path: path, queryItems: queryItems) else {
            throw BackendError.notAvailable(reason: "server not configured (host/token missing)")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = method
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        req.timeoutInterval = 600
        return req
    }

    public func prepare() async throws {
        let req = try request(path: "/v1/health")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw BackendError.notAvailable(reason: "server unreachable (\(String(data: data, encoding: .utf8) ?? ""))")
        }
        struct Health: Codable {
            var whisperModelReady: Bool?
            var whisperBin: Bool?
        }
        if let h = try? JSONDecoder().decode(Health.self, from: data) {
            if h.whisperBin == false {
                throw BackendError.notAvailable(reason: "whisper.cpp binary missing on server (brew install whisper-cpp)")
            }
            if modelId == nil, h.whisperModelReady == false {
                throw BackendError.assetMissing(locale: "whisper weights downloading on first use — retry shortly")
            }
        }
        if let modelId {
            struct Catalog: Codable {
                struct Model: Codable {
                    var id: String
                    var downloaded: Bool
                }
                var models: [Model]
            }
            let catalogRequest = try request(path: "/v1/models")
            let (catalogData, catalogResponse) = try await URLSession.shared.data(for: catalogRequest)
            guard (catalogResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw BackendError.notAvailable(reason: "could not read the server model catalog")
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: catalogData)
            guard catalog.models.first(where: { $0.id == modelId })?.downloaded == true else {
                throw BackendError.assetMissing(locale: "selected transcription model is not downloaded")
            }
        }
    }

    public func currentAssetState() async -> AssetState {
        do {
            try await prepare()
            return .ready
        } catch BackendError.assetMissing {
            return .notInstalled
        } catch {
            return .unavailable(reason: "\(error)")
        }
    }

    /// Lightweight health probe for Settings (never triggers downloads).
    public func serverHealth() async -> String {
        guard config.baseURL != nil, config.isConfigured else {
            return "Server connection not configured"
        }
        do {
            guard let endpoint = config.endpoint(path: "/v1/health") else {
                return "Server connection not configured"
            }
            var req = URLRequest(url: endpoint)
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return "Unreachable" }
            struct Health: Codable {
                var whisperBin: Bool?
                var whisperModelReady: Bool?
                var llmModelReady: Bool?
                var llamaLive: Bool?
            }
            let h = try JSONDecoder().decode(Health.self, from: data)
            var parts: [String] = []
            parts.append((h.whisperBin ?? false) ? "binaries ok" : "sidecars missing")
            parts.append((h.whisperModelReady ?? false) ? "whisper ready" : "whisper downloading")
            parts.append((h.llmModelReady ?? false) ? "qwen ready" : "qwen downloading")
            return parts.joined(separator: " · ")
        } catch {
            return "Unreachable — is the server running on \(config.host)?"
        }
    }

    public func startStreaming(sessionId: SessionID) async -> AsyncStream<BackendEvent> {
        let (stream, cont) = AsyncStream<BackendEvent>.makeStream()
        self.events = cont
        self.pcm = Data()
        self.finished = false
        self.requestId = sessionId.rawValue
        return stream
    }

    public func appendAudio(_ data: Data, timestamp: Double) async {
        guard !finished else { return }
        // Bound the upload: 10 minutes of 16kHz mono 16-bit.
        if pcm.count + data.count > 16_000 * 2 * 600 {
            events?.yield(.failure(.recognitionFailed(underlying: "utterance exceeds 10-minute bound")))
            events?.finish()
            events = nil
            finished = true
            return
        }
        pcm.append(data)
    }

    public func finishStreaming() async {
        guard !finished else { return }
        finished = true
        guard let cont = events else { return }
        events = nil
        do {
            let wav = WavEncoder().encode(pcm16: pcm, sampleRate: Int(sampleRate))
            let transcript = try await transcribe(wav: wav, requestId: requestId)
            let seg = SegmentRevision(segmentId: "whisper-0", revision: 0, text: transcript.text, isFinal: true)
            let alts = transcript.segments.enumerated().map { i, s in
                AlternativeHypothesis(segmentId: seg.segmentId, rank: i, text: s.text, tokenTexts: s.text.split(separator: " ").map(String.init))
            }
            cont.yield(.final(segment: seg, alternatives: alts))
            cont.finish()
        } catch {
            cont.yield(.failure(.recognitionFailed(underlying: "\(error)")))
            cont.finish()
        }
    }

    /// Retries a previously saved WAV without reopening the microphone.
    public func transcribeFile(url: URL, requestId: String = UUID().uuidString) async throws -> ServerTranscript {
        try await transcribe(wav: Data(contentsOf: url), requestId: requestId)
    }

    private func transcribe(wav: Data, requestId: String?) async throws -> ServerTranscript {
        var queryItems = [URLQueryItem(name: "language", value: config.language)]
        if let modelId { queryItems.append(URLQueryItem(name: "model", value: modelId)) }
        var req = try request(
            path: "/v1/transcribe",
            queryItems: queryItems,
            method: "POST",
            body: wav,
            contentType: "audio/wav"
        )
        if let requestId { req.setValue(requestId, forHTTPHeaderField: "X-Omil-Request-ID") }
        req.timeoutInterval = 900
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(code)"
            switch code {
            case 401:
                throw BackendError.notAvailable(reason: "server rejected token (check Settings → Server)")
            case 503:
                throw BackendError.assetMissing(locale: message)
            default:
                throw BackendError.recognitionFailed(underlying: message)
            }
        }
        return try JSONDecoder().decode(ServerTranscript.self, from: data)
    }

    public func cancelStreaming() async {
        finished = true
        events?.finish()
        events = nil
        pcm = Data()
        requestId = nil
    }
}

// MARK: - ServerCleanupClient (Qwen cleanup via Omil server)

public enum WritingStyle: String, Codable, Sendable, CaseIterable {
    case automatic
    case formal
    case casual
    case veryCasual
    case excited

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        case .excited: return "Excited"
        }
    }
}

public struct ServerToken: Codable, Sendable {
    public var id: String
    public var text: String
    public var normalized: String
    public var kind: String
    public var isProtected: Bool
}

public struct ServerEdit: Codable, Sendable {
    public var editId: String?
    public var op: String
    public var targetTokenIds: [String]
    public var evidenceTokenIds: [String]
    public var reason: String?
    public var replacementText: String?
}

public struct ServerAbstention: Codable, Sendable {
    public var reason: String
    public var detail: String
}

public struct ServerCleanedResult: Codable, Sendable {
    public var snapshotId: String
    public var tokens: [ServerToken]
    public var text: String
    public var acceptedEdits: [ServerEdit]
    public var rejected: [ServerRejectedEdit]
    public var abstentions: [ServerAbstention]
    public var rulesVersion: String
    public var appliedSnippetTriggers: [String]?
    public var writingStyle: WritingStyle?
}

public struct ServerRejectedEdit: Codable, Sendable {
    public var edit: ServerEdit
    public var reason: String
}

public enum ServerCleanupError: Error, Sendable {
    case notConfigured
    case unauthorized
    case modelUnavailable(reason: String)
    case failed(reason: String)
}

public struct ServerCleanupClient: Sendable {
    public var config: ServerConfig
    public var dictionary: PersonalDictionary
    public var snippets: [String: String]
    public var style: WritingStyle
    public var modelId: String?

    public init(
        config: ServerConfig,
        dictionary: PersonalDictionary = PersonalDictionary(),
        snippets: [String: String] = [:],
        style: WritingStyle = .automatic,
        modelId: String? = nil
    ) {
        self.config = config
        self.dictionary = dictionary
        self.snippets = snippets
        self.style = style
        self.modelId = modelId
    }

    public func clean(
        text: String,
        mode: CleanupMode,
        requestId: String? = nil
    ) async throws -> ServerCleanedResult {
        guard config.baseURL != nil, config.isConfigured else {
            throw ServerCleanupError.notConfigured
        }
        guard let endpoint = config.endpoint(path: "/v1/cleanup") else {
            throw ServerCleanupError.notConfigured
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let requestId { req.setValue(requestId, forHTTPHeaderField: "X-Omil-Request-ID") }
        req.timeoutInterval = 300
        var body: [String: Any] = [
            "text": text,
            "mode": mode == .verbatim ? "verbatim" : "clean",
            "dictionary": dictionary.entries,
            "snippets": snippets,
            "style": style.rawValue,
        ]
        if let modelId { body["model"] = modelId }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try JSONDecoder().decode(ServerCleanedResult.self, from: data)
        case 401:
            throw ServerCleanupError.unauthorized
        case 503:
            throw ServerCleanupError.modelUnavailable(reason: String(data: data, encoding: .utf8) ?? "")
        default:
            throw ServerCleanupError.failed(reason: String(data: data, encoding: .utf8) ?? "HTTP \(code)")
        }
    }
}
