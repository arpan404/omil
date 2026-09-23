import Foundation
import Testing
@testable import OmilCore

@Suite("Omil server client (offline)")
struct ServerClientTests {
    @Test func wavHeaderRoundTrip() {
        // 8 samples of silence, 16kHz mono.
        let pcm = Data(repeating: 0, count: 16)
        let wav = WavEncoder().encode(pcm16: pcm, sampleRate: 16_000)
        #expect(wav.count == 44 + 16)
        #expect(String(data: wav.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: wav[8..<12], encoding: .utf8) == "WAVE")
        #expect(String(data: wav[36..<40], encoding: .utf8) == "data")
        let rate: UInt32 = wav[24..<28].withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        #expect(rate == 16_000)
        #expect(wav.suffix(16) == pcm)
    }

    @Test func serverConfigURL() {
        let cfg = ServerConfig(host: "192.168.1.5", port: 3217, token: "abc")
        #expect(cfg.baseURL?.absoluteString == "http://192.168.1.5:3217")
        #expect(cfg.isConfigured)
        #expect(!ServerConfig(host: "", token: "").isConfigured)
    }

    @Test func transcriptionEndpointKeepsLanguageAsQuery() {
        let cfg = ServerConfig(host: "127.0.0.1", port: 3217, token: "test", language: "en-US")
        let url = cfg.endpoint(
            path: "/v1/transcribe",
            queryItems: [URLQueryItem(name: "language", value: cfg.language)]
        )
        #expect(url?.path == "/v1/transcribe")
        #expect(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "language", value: "en-US")
        ])
    }

    @Test func cleanupResponseDecodes() throws {
        let json = """
        {"snapshotId":"s1","tokens":[{"id":"s1-0","text":"Make","normalized":"make","kind":"word","isProtected":false}],
         "text":"Make it 21.","acceptedEdits":[{"op":"replaceFromSource","targetTokenIds":["s1-2"],"evidenceTokenIds":["s1-4"],"reason":"cue"}],
         "rejected":[],"abstentions":[],"rulesVersion":"omil-ts-1/qwen-hybrid+personalization",
         "appliedSnippetTriggers":["my intro"],"writingStyle":"casual"}
        """
        let r = try JSONDecoder().decode(ServerCleanedResult.self, from: Data(json.utf8))
        #expect(r.text == "Make it 21.")
        #expect(r.acceptedEdits.count == 1)
        #expect(r.rulesVersion.contains("qwen"))
        #expect(r.appliedSnippetTriggers == ["my intro"])
        #expect(r.writingStyle == .casual)
    }

    @Test func writingStyleWireValuesMatchServer() throws {
        #expect(WritingStyle.allCases.map(\.rawValue) == ["automatic", "formal", "casual", "veryCasual", "excited"])
        #expect(try JSONEncoder().encode(WritingStyle.veryCasual) == Data("\"veryCasual\"".utf8))
    }

    @Test func transcriptDecodes() throws {
        let json = """
        {"text":"Make it 42. Sorry, 21.","segments":[{"start":0.0,"end":1.2,"text":"Make it 42."}],"model":"whisper-large-v3-turbo"}
        """
        let t = try JSONDecoder().decode(ServerTranscript.self, from: Data(json.utf8))
        #expect(t.segments.count == 1)
        #expect(t.model.contains("whisper"))
    }

    @Test func serverBackendDeclaresNoPartials() {
        let b = ServerTranscriptionBackend(config: ServerConfig())
        #expect(b.capabilities.supportsPartials == false)
        #expect(b.capabilities.supportsTimestamps == true)
        #expect(b.identity == .server)
    }

    @Test func speechSensitivityHasStablePerRequestValues() {
        #expect(SpeechSensitivity.allCases.map(\.rawValue) == ["strict", "balanced", "distant"])
        #expect(SpeechSensitivity.distant.detail.contains("quieter"))
    }
}

@Suite("Server catalog consistency")
struct ServerCatalogTests {
    // Every downloadable weight file must map to the server's model id —
    // the server rejects unknown IDs with 400, so a missing mapping breaks
    // model switching. (Cross-check server/src/Config.ts MODELS on change.)
    @Test func everyWhisperFileMaps() {
        for f in ServerCatalog.whisperFiles {
            #expect(ServerCatalog.whisperIdForFile[f] != nil, "no server id for \(f)")
            #expect(ServerAssetsMirror.pinExists(f), "no download pin for \(f)")
        }
    }

    @Test func everyLlmFileMaps() {
        for f in ServerCatalog.llmFiles {
            #expect(ServerCatalog.llmIdForFile[f] != nil, "no server id for \(f)")
            #expect(ServerAssetsMirror.pinExists(f), "no download pin for \(f)")
        }
    }

    @Test func defaultsAreValid() {
        #expect(ServerCatalog.whisperIdForFile[ServerCatalog.defaultWhisperFile] == "whisper-large-v3-turbo")
        #expect(ServerCatalog.llmIdForFile[ServerCatalog.defaultLlmFile] == "qwen3-4b-instruct")
    }
}

/// Download pins live in the Mac app (ServerAssets). This mirror records the
/// pinned set so core tests fail if the catalog drifts from the downloader.
enum ServerAssetsMirror {
    static let pinnedIds: Set<String> = [
        "whisper-bin", "llama-bin",
        "ggml-tiny.bin", "ggml-base.bin", "ggml-small.bin",
        "ggml-medium.bin", "ggml-medium-32-2.en.bin",
        "ggml-distil-large-v3.bin", "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo.bin",
        "ggml-large-v3-q5_0.bin", "ggml-large-v3.bin",
        "Qwen3-0.6B-Q4_K_M.gguf", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        "Qwen3-8B-Q4_K_M.gguf", "Qwen3.5-0.8B-Q4_K_M.gguf",
        "Qwen3.5-4B-Q4_K_M.gguf", "Qwen3.5-9B-Q4_K_M.gguf",
    ]
    static func pinExists(_ id: String) -> Bool { pinnedIds.contains(id) }
}
