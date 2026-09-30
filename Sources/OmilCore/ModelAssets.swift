import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ModelAssets
//
// Integrity checks for model data (downloads themselves are owned by the server).

public enum AssetError: Error {
    case integrityMismatch(expected: String, actual: String)
}

/// Integrity + bookkeeping helpers (network fetch lives in the app layer so
/// the core stays testable and dependency-free).
public struct ModelAssets: Sendable {
    public init() {}

    public static func sha256(of data: Data) -> String {
        // Use CryptoKit when available; fallback FNV for non-Apple test hosts.
        #if canImport(CryptoKit)
        if #available(macOS 10.15, iOS 13, *) {
            return CryptoKitSHA256.hex(data)
        }
        #endif
        return "fnv1a-\(fnv1a(data))"

    }

    static func fnv1a(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    public static func verify(data: Data, expectedSHA256: String?) -> Result<Void, AssetError> {
        guard let expected = expectedSHA256 else {
            // No checksum pinned: explicit unverified state (caller decides).
            return .success(())
        }
        let actual = sha256(of: data)
        if actual.lowercased() == expected.lowercased() { return .success(()) }
        return .failure(.integrityMismatch(expected: expected, actual: actual))
    }
}

#if canImport(CryptoKit)
import CryptoKit
@available(macOS 10.15, iOS 13, *)
enum CryptoKitSHA256 {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif

// MARK: - CapabilityMatrix

public struct CapabilityMatrix: Sendable {
    public init() {}

    /// Chooses an on-device speech backend from runtime availability.
    public func eligible(status: AppleSpeechStatus, memoryGB: Int, executionState: String) -> (supported: Bool, notes: String) {
        if status.speechTranscriberAvailable {
            return (true, "Apple SpeechTranscriber available; \(status.detail)")
        }
        if status.sfOnDeviceAvailable {
            return (executionState == "foreground", "SFSpeech on-device fallback; background unverified")
        }
        return (false, "no on-device backend: \(status.detail)")
    }

    public static func currentDevice() -> (model: String, os: String, memoryGB: Int) {
        #if os(macOS) || os(iOS)
        let mem = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        #if os(iOS)
        #if canImport(UIKit)
        let model = UIDevice.current.model
        #else
        let model = "iPhone/iPad"
        #endif
        #else
        let model = "Mac"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return (model, os, mem)
        #else
        return ("unknown", "unknown", 0)
        #endif
    }
}
