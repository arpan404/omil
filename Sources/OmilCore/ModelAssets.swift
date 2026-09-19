import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - ModelAssets
//
// Explicit, versioned, integrity-checked model downloads owned by the app.
// Weights are data consumed by shipped runtimes (never executable code).

public struct ModelManifestEntry: Codable, Sendable {
    public var id: String           // e.g. "whisperkit-small.en"
    public var version: String
    public var languages: [String]
    public var downloadBytes: Int
    public var installedBytes: Int?
    public var minRAMClass: String  // e.g. "6GB"
    public var estimatedPeakMB: Int?
    public var license: String
    public var licenseURL: String?
    public var sourceURL: String
    public var sha256: String?
    public var benchmarkDevice: String?
    public init(id: String, version: String, languages: [String], downloadBytes: Int, license: String, sourceURL: String, minRAMClass: String = "6GB") {
        self.id = id
        self.version = version
        self.languages = languages
        self.downloadBytes = downloadBytes
        self.license = license
        self.sourceURL = sourceURL
        self.minRAMClass = minRAMClass
    }
}

public enum ModelInstallState: String, Codable, Sendable {
    case notInstalled
    case downloading
    case verifying
    case installed
    case failed
}

public struct ModelInstallRecord: Codable, Sendable {
    public var entry: ModelManifestEntry
    public var state: ModelInstallState
    public var progress: Double
    public var installedPath: String?
    public var failureReason: String?
    public init(entry: ModelManifestEntry) {
        self.entry = entry
        self.state = .notInstalled
        self.progress = 0
    }
}

public enum AssetError: Error {
    case integrityMismatch(expected: String, actual: String)
    case downloadFailed(underlying: String)
    case unsupportedPlatform
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

/// Eligibility from measured evidence + runtime probes (never chip names).
public struct DeviceCapability: Codable, Sendable {
    public var deviceModel: String
    public var osVersion: String
    public var memoryGB: Int
    public var backend: String
    public var locale: String
    public var executionState: String // foreground / background
    public var supported: Bool
    public var notes: String
    public init(deviceModel: String, osVersion: String, memoryGB: Int, backend: String, locale: String, executionState: String, supported: Bool, notes: String) {
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.memoryGB = memoryGB
        self.backend = backend
        self.locale = locale
        self.executionState = executionState
        self.supported = supported
        self.notes = notes
    }
}

public struct CapabilityMatrix: Sendable {
    public init() {}

    /// Starting policy to validate (product plan): runtime availability first.
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
