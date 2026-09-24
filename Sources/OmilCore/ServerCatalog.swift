import Foundation

// MARK: - ServerCatalog
//
// Model IDs shared between Swift clients and the Effect server
// (server/src/Config.ts MODELS). The server rejects unknown IDs with 400,
// so every option offered in UI must map here.

public struct ServerCatalog: Sendable {
    /// Weight filenames offered for download, per role.
    public static let whisperFiles: [String] = [
        "ggml-small-q8_0.bin", "ggml-large-v3-turbo-q8_0.bin",
    ]
    public static let llmFiles: [String] = [
        "Qwen3.5-0.8B-Q4_K_M.gguf",
        "Qwen3.5-2B-Q4_K_M.gguf",
        "Qwen3.5-4B-Q4_K_M.gguf",
    ]

    /// Weight filename -> request-scoped server model id.
    public static let whisperIdForFile: [String: String] = [
        "ggml-small-q8_0.bin": "whisper-small-q8",
        "ggml-large-v3-turbo-q8_0.bin": "whisper-large-v3-turbo-q8",
    ]
    public static let llmIdForFile: [String: String] = [
        "Qwen3.5-0.8B-Q4_K_M.gguf": "qwen3.5-0.8b",
        "Qwen3.5-2B-Q4_K_M.gguf": "qwen3.5-2b",
        "Qwen3.5-4B-Q4_K_M.gguf": "qwen3.5-4b",
    ]

    public static let defaultWhisperFile = "ggml-large-v3-turbo-q8_0.bin"
    public static let defaultLlmFile = "Qwen3.5-2B-Q4_K_M.gguf"
}
