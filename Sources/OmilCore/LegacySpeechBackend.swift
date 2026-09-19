import Foundation
import AVFAudio
#if canImport(Speech)
import Speech
#endif

// MARK: - LegacySpeechBackend (SFSpeechRecognizer, on-device enforced)
//
// Fallback where SpeechTranscriber is unavailable. Recognition is pinned
// on-device: the recognizer must report supportsOnDeviceRecognition and the
// request sets requiresOnDeviceRecognition. No network fallback exists in Omil.

#if canImport(Speech)
public actor LegacySpeechBackend: TranscriptionBackend {
    public nonisolated let identity: BackendIdentity
    public nonisolated let capabilities = BackendCapabilities(
        supportsStreaming: true, supportsPartials: true, supportsTimestamps: false,
        supportsAlternatives: true, requiresAssetDownload: false)
    public nonisolated let requiredAudioFormat = AudioFormatRequirements(
        sampleRate: 16_000, channelCount: 1, description: "SFSpeech 16kHz mono PCM")
    public nonisolated let locale: String

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var events: AsyncStream<BackendEvent>.Continuation?
    private var revision = 0

    public init(locale: String = "en-US") {
        self.locale = locale
        self.identity = .sfspeech(locale: locale)
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }

    public func prepare() async throws {
        guard let rec = recognizer, rec.isAvailable else {
            throw BackendError.notAvailable(reason: "SFSpeechRecognizer unavailable for \(locale)")
        }
        guard rec.supportsOnDeviceRecognition else {
            throw BackendError.notAvailable(reason: "on-device recognition unsupported for \(locale)")
        }
        return try await withCheckedThrowingContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                if status == .authorized {
                    cont.resume()
                } else {
                    cont.resume(throwing: BackendError.notAvailable(reason: "speech permission \(status)"))
                }
            }
        }
    }

    public func currentAssetState() async -> AssetState {
        guard let rec = recognizer, rec.isAvailable, rec.supportsOnDeviceRecognition else {
            return .unavailable(reason: "SFSpeech on-device unavailable for \(locale)")
        }
        return .ready
    }

    public func startStreaming(sessionId: SessionID) async -> AsyncStream<BackendEvent> {
        let (stream, cont) = AsyncStream<BackendEvent>.makeStream()
        self.events = cont
        self.revision = 0
        guard let rec = recognizer else {
            cont.yield(.failure(.notAvailable(reason: "no recognizer")))
            cont.finish()
            return stream
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        // Prefer alternatives when the recognizer provides them.
        if rec.supportsOnDeviceRecognition {
            req.taskHint = .dictation
        }
        self.request = req
        self.task = rec.recognitionTask(with: req) { [weak self] result, error in
            // Extract Sendable values synchronously; hop to the actor after.
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let alts = result.map { Array($0.transcriptions.dropFirst().map { $0.formattedString }) } ?? []
            let errCode = (error as NSError?)?.code
            let errDesc = error.map { "\($0)" }
            guard let self else { return }
            Task { await self.handle(text: text, isFinal: isFinal, alternatives: alts, errorCode: errCode, errorDescription: errDesc) }
        }
        return stream
    }

    private func handle(text: String?, isFinal: Bool, alternatives: [String], errorCode: Int?, errorDescription: String?) async {
        guard let cont = events else { return }
        if let code = errorCode {
            if code == 216 { // cancelled
                cont.finish()
            } else {
                cont.yield(.failure(.recognitionFailed(underlying: errorDescription ?? "code \(code)")))
                cont.finish()
            }
            return
        }
        guard let text else { return }
        let seg = SegmentRevision(segmentId: "sf-\(revision)", revision: revision, text: text, isFinal: isFinal)
        revision += 1
        if isFinal {
            let hyps = alternatives.enumerated().map { i, t in
                AlternativeHypothesis(segmentId: seg.segmentId, rank: i + 1, text: t, tokenTexts: t.split(separator: " ").map(String.init))
            }
            cont.yield(.final(segment: seg, alternatives: hyps))
        } else {
            cont.yield(.partial(segment: seg))
        }
        if isFinal {
            cont.finish()
            events = nil
        }
    }

    public func appendAudio(_ data: Data, timestamp: Double) async {
        guard let request else { return }
        // 16 kHz mono Int16 -> AVAudioPCMBuffer for the recognition request.
        let frames = data.count / 2
        guard frames > 0,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { ptr in
            guard let src = ptr.baseAddress else { return }
            memcpy(buffer.int16ChannelData![0], src, data.count)
        }
        request.append(buffer)
    }

    public func finishStreaming() async {
        request?.endAudio()
    }

    public func cancelStreaming() async {
        task?.cancel()
        task = nil
        request = nil
        events?.finish()
        events = nil
    }
}
#endif
