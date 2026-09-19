import Foundation
import AVFAudio
import CoreMedia
#if canImport(Speech)
import Speech
#endif

// MARK: - AppleSpeechBackend
//
// Primary candidate: SpeechAnalyzer/SpeechTranscriber (OS 26+).
// Audio format is negotiated per backend via bestAvailableAudioFormat /
// availableCompatibleAudioFormats; SpeechAnalyzer does not resample for us.

public struct AppleSpeechStatus: Hashable, Sendable {
    public var speechTranscriberAvailable: Bool
    public var dictationAvailable: Bool
    public var sfOnDeviceAvailable: Bool
    public var installedLocales: [String]
    public var detail: String
}

#if canImport(Speech)
@available(macOS 26, iOS 26, *)
public actor AppleSpeechBackend: TranscriptionBackend {
    public nonisolated let identity: BackendIdentity = .appleSpeech(configuration: "SpeechTranscriber")
    public nonisolated let capabilities = BackendCapabilities(
        supportsStreaming: true, supportsPartials: true, supportsTimestamps: true,
        supportsAlternatives: true, requiresAssetDownload: true)
    public nonisolated let locale: String

    let transcriber: SpeechTranscriber
    var analyzer: SpeechAnalyzer?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var outputTask: Task<Void, Never>?
    var eventsContinuation: AsyncStream<BackendEvent>.Continuation?
    var negotiatedFormat: AVAudioFormat?
    var converter: AVAudioConverter?
    var pendingFrames: Int = 0

    public nonisolated var requiredAudioFormat: AudioFormatRequirements {
        AudioFormatRequirements(description: "negotiated via bestAvailableAudioFormat at prepare()")
    }

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale.identifier
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange])
    }

    public func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw BackendError.notAvailable(reason: "SpeechTranscriber.isAvailable == false")
        }
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed, .supported:
            break
        case .downloading:
            break // proceed; installation request below is a no-op if active
        case .unsupported:
            throw BackendError.assetMissing(locale: locale)
        @unknown default:
            break
        }
        if status != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        // Negotiate the input format from installed assets.
        if let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber] as [any SpeechModule]) {
            negotiatedFormat = fmt
        } else if let first = await transcriber.availableCompatibleAudioFormats.first {
            negotiatedFormat = first
        } else {
            throw BackendError.audioFormatUnsupported(detail: "no compatible audio format reported")
        }
    }

    public func currentAssetState() async -> AssetState {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable(reason: "SpeechTranscriber.isAvailable == false for \(locale)")
        }
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed: return .ready
        case .downloading: return .downloading(progress: -1)
        case .supported: return .notInstalled
        case .unsupported: return .unavailable(reason: "locale \(locale) unsupported")
        @unknown default: return .unavailable(reason: "unknown asset status")
        }
    }

    public func startStreaming(sessionId: SessionID) async -> AsyncStream<BackendEvent> {
        let (stream, cont) = AsyncStream<BackendEvent>.makeStream()
        self.eventsContinuation = cont
        let (inputs, inputCont) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputCont
        let transcriber = self.transcriber
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        if let fmt = negotiatedFormat {
            Task { try? await analyzer.prepareToAnalyze(in: fmt) }
        }
        outputTask = Task {
            do {
                // Feed input on a child task so result iteration starts immediately.
                let feed = Task { try await analyzer.start(inputSequence: inputs) }
                var revision = 0
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let alts = result.alternatives.map { String($0.characters) }
                    let seg = SegmentRevision(
                        segmentId: "apple-\(revision)", revision: revision,
                        text: text, isFinal: result.isFinal,
                        startTime: result.range.start.seconds.isFinite ? result.range.start.seconds : nil,
                        endTime: result.range.end.seconds.isFinite ? result.range.end.seconds : nil)
                    revision += 1
                    if result.isFinal {
                        let hyps = alts.enumerated().map { i, t in
                            AlternativeHypothesis(segmentId: seg.segmentId, rank: i + 1, text: t, tokenTexts: t.split(separator: " ").map(String.init))
                        }
                        cont.yield(.final(segment: seg, alternatives: hyps))
                    } else {
                        cont.yield(.partial(segment: seg))
                    }
                }
                try await feed.value
                cont.finish()
            } catch {
                if error is CancellationError {
                    cont.finish()
                } else {
                    cont.yield(.failure(.recognitionFailed(underlying: "\(error)")))
                    cont.finish()
                }
            }
        }
        return stream
    }

    /// PCM path used by the platform adapter: converts Int16 mono PCM `data`
    /// (at `sampleRate`) into the negotiated format and forwards buffers.
    public func appendPCM16(data: Data, sampleRate: Double, timestamp: Double) async {
        guard let inputCont = inputContinuation, let target = negotiatedFormat else { return }
        guard let buffer = Self.pcmBuffer(from: data, sampleRate: sampleRate, channels: 1) else { return }
        if let conv = converter {
            // Convert into target format.
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate + 16)) else { return }
            var consumed = false
            var convError: NSError?
            let status = conv.convert(to: out, error: &convError, withInputFrom: { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            })
            if convError == nil, status != .error, out.frameLength > 0 {
                let t = CMTime(seconds: timestamp, preferredTimescale: 1_000_000)
                inputCont.yield(AnalyzerInput(buffer: out, bufferStartTime: t))
                pendingFrames += Int(out.frameLength)
            }
        } else if let direct = converterIfMatching(buffer.format, target: target) {
            _ = direct
            let t = CMTime(seconds: timestamp, preferredTimescale: 1_000_000)
            inputCont.yield(AnalyzerInput(buffer: buffer, bufferStartTime: t))
        } else {
            guard let conv = AVAudioConverter(from: buffer.format, to: target) else { return }
            self.converter = conv
            await appendPCM16(data: data, sampleRate: sampleRate, timestamp: timestamp)
        }
    }

    public func appendAudio(_ data: Data, timestamp: Double) async {
        // Default PCM assumption for the generic path: 16 kHz mono Int16.
        await appendPCM16(data: data, sampleRate: 16_000, timestamp: timestamp)
    }

    public func finishStreaming() async {
        inputContinuation?.finish()
        inputContinuation = nil
    }

    public func cancelStreaming() async {
        outputTask?.cancel()
        outputTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let a = analyzer {
            await a.cancelAndFinishNow()
        }
        analyzer = nil
        eventsContinuation?.finish()
        eventsContinuation = nil
        converter = nil
    }

    /// Negotiated input format for the installed assets. Query after prepare().
    public func audioFormat() async -> AVAudioFormat? { negotiatedFormat }

    // MARK: PCM helpers

    static func pcmBuffer(from data: Data, sampleRate: Double, channels: Int) -> AVAudioPCMBuffer? {
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true) else { return nil }
        let frames = data.count / (2 * channels)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { ptr in
            guard let src = ptr.baseAddress else { return }
            memcpy(buffer.int16ChannelData![0], src, data.count)
        }
        return buffer
    }

    /// Returns non-nil when no conversion is needed.
    func converterIfMatching(_ from: AVAudioFormat, target: AVAudioFormat) -> Bool? {
        if from.sampleRate == target.sampleRate && from.channelCount == target.channelCount { return true }
        return nil
    }
}

@available(macOS 26, iOS 26, *)
extension AppleSpeechBackend {
    public static func probe(locale: Locale = Locale(identifier: "en-US")) async -> AppleSpeechStatus {
        let installed = await SpeechTranscriber.installedLocales.map { $0.identifier }
        let rec = SFSpeechRecognizer(locale: locale)
        return AppleSpeechStatus(
            speechTranscriberAvailable: SpeechTranscriber.isAvailable,
            dictationAvailable: true,
            sfOnDeviceAvailable: rec?.supportsOnDeviceRecognition ?? false,
            installedLocales: installed,
            detail: "SpeechTranscriber.isAvailable=\(SpeechTranscriber.isAvailable)")
    }
}
#endif

// MARK: - Runtime capability probe (all OS versions)

public struct SpeechSupportProbe: Sendable {
    public init() {}

    public func probe(locale: Locale = Locale(identifier: "en-US")) async -> AppleSpeechStatus {
        #if canImport(Speech)
        if #available(macOS 26, iOS 26, *) {
            return await AppleSpeechBackend.probe(locale: locale)
        }
        let rec = SFSpeechRecognizer(locale: locale)
        let onDevice = rec?.supportsOnDeviceRecognition ?? false
        return AppleSpeechStatus(
            speechTranscriberAvailable: false,
            dictationAvailable: false,
            sfOnDeviceAvailable: onDevice,
            installedLocales: SFSpeechRecognizer.supportedLocales().map { $0.identifier },
            detail: "legacy SFSpeechRecognizer; onDevice=\(onDevice) recAvailable=\(rec?.isAvailable ?? false)")
        #else
        return AppleSpeechStatus(
            speechTranscriberAvailable: false, dictationAvailable: false,
            sfOnDeviceAvailable: false, installedLocales: [],
            detail: "Speech framework unavailable")
        #endif
    }
}
