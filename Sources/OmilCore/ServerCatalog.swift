import Foundation

// MARK: - ServerCatalog
//
// Model IDs shared between Swift clients and the Effect server
// (server/src/Config.ts MODELS). The server rejects unknown IDs with 400,
// so every option offered in UI must map here.

public struct ServerCatalog: Sendable {
    /// Weight filenames offered for download, per role.
    public static let whisperFiles: [String] = [
        "ggml-tiny.bin", "ggml-base.bin", "ggml-small.bin",
        "ggml-medium.bin", "ggml-medium-32-2.en.bin",
        "ggml-distil-large-v3.bin", "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo.bin",
        "ggml-large-v3-q5_0.bin", "ggml-large-v3.bin",
    ]
    public static let llmFiles: [String] = [
        "Qwen3-0.6B-Q4_K_M.gguf",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        "Qwen3-8B-Q4_K_M.gguf",
        "Qwen3.5-0.8B-Q4_K_M.gguf",
        "Qwen3.5-4B-Q4_K_M.gguf",
        "Qwen3.5-9B-Q4_K_M.gguf",
    ]

    /// Weight filename -> request-scoped server model id.
    public static let whisperIdForFile: [String: String] = [
        "ggml-tiny.bin": "whisper-tiny", "ggml-base.bin": "whisper-base",
        "ggml-small.bin": "whisper-small", "ggml-medium.bin": "whisper-medium",
        "ggml-medium-32-2.en.bin": "distil-whisper-medium-en",
        "ggml-distil-large-v3.bin": "distil-whisper-large-v3",
        "ggml-large-v3-turbo-q5_0.bin": "whisper-large-v3-turbo-q5",
        "ggml-large-v3-turbo-q8_0.bin": "whisper-large-v3-turbo-q8",
        "ggml-large-v3-turbo.bin": "whisper-large-v3-turbo",
        "ggml-large-v3-q5_0.bin": "whisper-large-v3-q5",
        "ggml-large-v3.bin": "whisper-large-v3",
    ]
    public static let llmIdForFile: [String: String] = [
        "Qwen3-0.6B-Q4_K_M.gguf": "qwen3-0.6b",
        "Qwen3-4B-Instruct-2507-Q4_K_M.gguf": "qwen3-4b-instruct",
        "Qwen3-8B-Q4_K_M.gguf": "qwen3-8b",
        "Qwen3.5-0.8B-Q4_K_M.gguf": "qwen3.5-0.8b",
        "Qwen3.5-4B-Q4_K_M.gguf": "qwen3.5-4b",
        "Qwen3.5-9B-Q4_K_M.gguf": "qwen3.5-9b",
    ]

    public static let defaultWhisperFile = "ggml-large-v3-turbo.bin"
    public static let defaultLlmFile = "Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
}
