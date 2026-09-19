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

    @Test func cleanupResponseDecodes() throws {
        let json = """
        {"snapshotId":"s1","tokens":[{"id":"s1-0","text":"Make","normalized":"make","kind":"word","isProtected":false}],
         "text":"Make it 21.","acceptedEdits":[{"op":"replaceFromSource","targetTokenIds":["s1-2"],"evidenceTokenIds":["s1-4"],"reason":"cue"}],
         "rejected":[],"abstentions":[],"rulesVersion":"omil-ts-1/qwen-hybrid"}
        """
        let r = try JSONDecoder().decode(ServerCleanedResult.self, from: Data(json.utf8))
        #expect(r.text == "Make it 21.")
        #expect(r.acceptedEdits.count == 1)
        #expect(r.rulesVersion.contains("qwen"))
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
}
