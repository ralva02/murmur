@preconcurrency import AVFAudio
import Foundation
import Speech

/// Streaming on-device ASR (spec §3.1 stages 1–3): AVAudioEngine mic capture
/// feeding Apple's SpeechAnalyzer/SpeechTranscriber while the user speaks.
/// Dictionary terms and on-screen proper nouns bias recognition via
/// AnalysisContext.contextualStrings.
@MainActor
final class AudioTranscriber {

    enum TranscriberError: LocalizedError {
        case localeUnsupported(String)
        case assetsUnavailable
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeUnsupported(let l): "Speech recognition does not support \(l)"
            case .assetsUnavailable: "Speech model assets are not installed"
            case .noAudioFormat: "No compatible audio format for transcription"
            }
        }
    }

    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?

    private(set) var finalizedText = ""
    private(set) var volatileText = ""

    /// Called on the main actor with the running transcript (finalized + volatile).
    var onPartial: ((String) -> Void)?

    var isRunning: Bool { analyzer != nil }

    /// Downloads model assets for the locale if needed. Safe to call repeatedly.
    static func ensureAssets(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        switch await AssetInventory.status(forModules: [probe]) {
        case .installed:
            return
        case .unsupported:
            throw TranscriberError.localeUnsupported(locale.identifier)
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            break
        }
    }

    func start(locale: Locale, contextualStrings: [String]) async throws {
        guard !isRunning else { return }
        finalizedText = ""
        volatileText = ""

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriberError.localeUnsupported(locale.identifier)
        }
        try await Self.ensureAssets(locale: supported)

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        self.transcriber = transcriber

        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence,
            modules: [transcriber],
            analysisContext: context)
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedText += text
                        self.volatileText = ""
                    } else {
                        self.volatileText = text
                    }
                    self.onPartial?(self.currentTranscript())
                }
            } catch {
                // Stream ends on stop/cancel; errors surface via the empty transcript.
            }
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: audioEngine.inputNode.outputFormat(forBus: 0)
        ) else {
            throw TranscriberError.noAudioFormat
        }

        let micFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        // Without microphone permission the input format is 0 Hz and
        // installTap raises an unrecoverable ObjC exception.
        guard micFormat.sampleRate > 0,
              let tapConverter = AVAudioConverter(from: micFormat, to: analyzerFormat) else {
            throw TranscriberError.noAudioFormat
        }
        converter = tapConverter

        Self.installStreamTap(
            on: audioEngine, converter: tapConverter,
            format: analyzerFormat, continuation: continuation)

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// The tap closure runs on the audio thread. It must be formed in a
    /// nonisolated context — created inside a @MainActor method it would
    /// inherit main-actor isolation and trap the isolation assertion when
    /// the audio thread invokes it. Only locals are captured, never self.
    private nonisolated static func installStreamTap(
        on engine: AVAudioEngine,
        converter: AVAudioConverter,
        format: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let micFormat = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: micFormat) {
            buffer, _ in
            guard let converted = convert(buffer: buffer, with: converter, to: format)
            else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    nonisolated private static func convert(
        buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? out : nil
    }

    func currentTranscript() -> String {
        (finalizedText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stops capture, finalizes recognition, returns the full transcript.
    ///
    /// Finalization can take 1–2 s, but the volatile transcript is essentially
    /// complete at release and the cleanup LLM re-punctuates anyway — so the
    /// wait is capped and the live transcript used when finalization is slow.
    func stop() async -> String {
        guard let analyzer else { return "" }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil

        let results = resultsTask
        let finalized = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                await results?.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(700))
                return false
            }
            let winner = await group.next() ?? false
            group.cancelAll()
            return winner
        }
        if !finalized {
            Diag.dictation.notice("ASR finalize exceeded 700ms; using live transcript")
            Task { await analyzer.cancelAndFinishNow() }   // background teardown
        }

        resultsTask?.cancel()
        resultsTask = nil
        self.analyzer = nil
        self.transcriber = nil
        self.converter = nil

        return currentTranscript()
    }

    /// Discards the session without returning text.
    func cancel() async {
        guard let analyzer else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer.cancelAndFinishNow()
        resultsTask?.cancel()
        resultsTask = nil
        self.analyzer = nil
        self.transcriber = nil
        self.converter = nil
        finalizedText = ""
        volatileText = ""
    }
}
