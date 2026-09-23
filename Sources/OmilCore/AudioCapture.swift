import Foundation
@preconcurrency import AVFAudio
#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - AudioCapture
//
// Bounded microphone pipeline: AVAudioEngine tap -> (convert) -> Int16 PCM
// chunks forwarded off the tap callback. Tap work stays lightweight; model
// work happens off the audio thread. Ring keeps pre-roll for endpointing.

public enum CaptureState: String, Sendable {
    case idle, starting, recording, stopping, stopped, failed
}

public enum CaptureError: Error, Sendable {
    case permissionDenied
    case noInputDevice
    case engineFailure(underlying: String)
    case formatUnsupported(detail: String)
}

public struct CapturedChunk: Sendable {
    public var pcm16: Data
    public var sampleRate: Double
    public var timestamp: Double // seconds since capture start
    public var isFinal: Bool
    public init(pcm16: Data, sampleRate: Double, timestamp: Double, isFinal: Bool = false) {
        self.pcm16 = pcm16
        self.sampleRate = sampleRate
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}

/// Preserves capture order and drains queued chunks before ASR finalization.
public final class AudioChunkForwarder: Sendable {
    private let continuation: AsyncStream<CapturedChunk>.Continuation
    private let worker: Task<Void, Never>

    public init(consume: @escaping @Sendable (CapturedChunk) async -> Void) {
        let (stream, continuation) = AsyncStream<CapturedChunk>.makeStream()
        self.continuation = continuation
        self.worker = Task {
            for await chunk in stream {
                await consume(chunk)
            }
        }
    }

    public func append(_ chunk: CapturedChunk) {
        continuation.yield(chunk)
    }

    public func finish() async {
        continuation.finish()
        await worker.value
    }

    public func cancel() {
        continuation.finish()
        worker.cancel()
    }
}

/// Converts captured PCM16 samples into a display-ready microphone level.
/// The logarithmic scale keeps speech readable while a noise gate holds true
/// silence at zero. This value is for UI feedback, not audio processing.
public enum AudioLevelMeter {
    public static func normalizedRMS(pcm16: Data, floorDB: Double = -60) -> Double {
        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        let sumOfSquares = pcm16.withUnsafeBytes { bytes -> Double in
            var sum = 0.0
            for offset in stride(from: 0, to: sampleCount * 2, by: 2) {
                let raw = bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                let sample = Double(Int16(littleEndian: raw)) / 32_768.0
                sum += sample * sample
            }
            return sum
        }

        let rms = sqrt(sumOfSquares / Double(sampleCount))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        let linear = min(1, max(0, (decibels - floorDB) / -floorDB))
        return pow(linear, 0.72)
    }
}

#if os(macOS) || os(iOS)
/// Microphone capture with a bounded buffer. Callbacks are invoked off the
/// audio thread; the tap itself only copies bytes.
public final class AudioCapture: NSObject, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var chunkHandler: (@Sendable (CapturedChunk) -> Void)?
    private var startedAt: Date?
    private let lock = NSLock()
    private var _state: CaptureState = .idle
    private var accumulatedFrames: Int = 0
    /// Hard bound: 10 minutes at 16 kHz mono 16-bit ~= 19.2 MB.
    public static let maxBytes = 16_000 * 2 * 600

    public var state: CaptureState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    private func setState(_ s: CaptureState) {
        lock.lock(); _state = s; lock.unlock()
    }

    public override init() { super.init() }

    /// Request microphone permission. Call from the feature entry point.
    public static func requestPermission() async -> Bool {
        #if os(iOS)
        return await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        #else
        return await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        #endif
    }

    /// Start capture. `targetSampleRate/targetChannels` come from the backend's
    /// negotiated format; conversion preserves sample-accurate timing via
    /// frame counts.
    public func start(
        targetSampleRate: Double? = nil,
        targetChannels: Int? = nil,
        chunkHandler: @escaping @Sendable (CapturedChunk) -> Void
    ) throws {
        setState(.starting)
        self.chunkHandler = chunkHandler
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            setState(.failed)
            throw CaptureError.noInputDevice
        }
        let outRate = targetSampleRate ?? inputFormat.sampleRate
        let outChannels = targetChannels ?? 1
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate, channels: AVAudioChannelCount(outChannels), interleaved: true) else {
            setState(.failed)
            throw CaptureError.formatUnsupported(detail: "cannot build Int16 \(outRate)Hz x\(outChannels)")
        }
        self.targetFormat = target
        if target.sampleRate != inputFormat.sampleRate || target.channelCount != inputFormat.channelCount {
            self.converter = AVAudioConverter(from: inputFormat, to: target)
        } else {
            self.converter = nil
        }
        startedAt = Date()
        accumulatedFrames = 0
        // 1024-frame taps keep the callback lightweight.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer)
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.chunkHandler = nil
            converter = nil
            targetFormat = nil
            setState(.failed)
            throw CaptureError.engineFailure(underlying: "\(error)")
        }
        setState(.recording)
    }

    private func handleTap(buffer: AVAudioPCMBuffer) {
        guard state == .recording else { return }
        let handler = chunkHandler
        let start = startedAt ?? Date()
        let elapsed = Date().timeIntervalSince(start)
        var out16 = Data()
        var outRate = buffer.format.sampleRate
        if let conv = converter, let target = targetFormat {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 8)) else { return }
            // Block-based conversion (single input buffer).
            var consumed = false
            var convError: NSError?
            let status = conv.convert(to: outBuf, error: &convError, withInputFrom: { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            })
            guard convError == nil, status != .error, outBuf.frameLength > 0 else { return }
            let frames = Int(outBuf.frameLength)
            out16 = Data(bytes: outBuf.int16ChannelData![0], count: frames * Int(target.channelCount) * 2)
            outRate = target.sampleRate
        } else {
            // Convert float32 -> int16 directly.
            guard let src = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            out16.reserveCapacity(frames * 2)
            // Downmix to mono when needed.
            for f in 0 ..< frames {
                var sample: Float = 0
                for c in 0 ..< channels { sample += src[c][f] }
                sample /= Float(max(1, channels))
                let clamped = max(-1.0, min(1.0, sample))
                var s16 = Int16(clamped * 32767)
                withUnsafeBytes(of: &s16) { out16.append(contentsOf: $0) }
            }
        }
        accumulatedFrames += out16.count / 2
        if accumulatedFrames * MemoryLayout<Int16>.size > Self.maxBytes {
            // Bound the pipeline: stop with a clear state instead of growing.
            stop()
            return
        }
        handler?(CapturedChunk(pcm16: out16, sampleRate: outRate, timestamp: elapsed))
    }

    public func stop() {
        if state != .recording { return }
        setState(.stopping)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunkHandler = nil
        converter = nil
        targetFormat = nil
        setState(.stopped)
    }

    public func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        chunkHandler = nil
        converter = nil
        targetFormat = nil
        setState(.idle)
    }
}
#else
public final class AudioCapture: NSObject, @unchecked Sendable {
    public var state: CaptureState { .failed }
    public static func requestPermission() async -> Bool { false }
    public func start(targetSampleRate: Double? = nil, targetChannels: Int? = nil, chunkHandler: @escaping @Sendable (CapturedChunk) -> Void) throws {
        throw CaptureError.noInputDevice
    }
    public func stop() {}
    public func cancel() {}
}
#endif
