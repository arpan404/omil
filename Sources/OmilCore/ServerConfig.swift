import Foundation

// MARK: - ServerConfig
//
// Connection to the Omil inference core (Effect/TS server on the user's own
// Mac): Whisper transcription + Qwen cleanup. Swift apps are thin clients —
// they capture audio, display results, and insert text locally.

public struct ServerConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var language: String

    public init(host: String = "127.0.0.1", port: Int = 3217, token: String = "", language: String = "en") {
        self.host = host
        self.port = port
        self.token = token
        self.language = language
    }

    public var baseURL: URL? {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host.isEmpty ? nil : host
        comps.port = port
        return comps.url
    }

    public func endpoint(path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let baseURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    public var isConfigured: Bool {
        !(host.trimmingCharacters(in: .whitespaces).isEmpty || token.isEmpty)
    }
}

// MARK: - WAV encoding (PCM16 mono -> WAV bytes for upload)

public struct WavEncoder: Sendable {
    public init() {}

    public func encode(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var out = Data()
        func u32(_ v: UInt32) {
            var x = v.littleEndian
            out.append(Data(bytes: &x, count: 4))
        }
        func u16(_ v: UInt16) {
            var x = v.littleEndian
            out.append(Data(bytes: &x, count: 2))
        }
        let byteRate = sampleRate * channels * 2
        out.append(contentsOf: "RIFF".utf8)
        u32(UInt32(36 + pcm16.count))
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: "fmt ".utf8)
        u32(16)
        u16(1) // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(channels * 2))
        u16(16)
        out.append(contentsOf: "data".utf8)
        u32(UInt32(pcm16.count))
        out.append(pcm16)
        return out
    }
}
