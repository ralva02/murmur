@preconcurrency import AVFAudio
import Foundation
import Speech

/// On-device transcription of an audio file via SpeechAnalyzer.
/// Accuracy over latency: full finalization, no cap (unlike live dictation).
@MainActor
final class FileTranscriber {

    enum FileTranscriberError: LocalizedError {
        case unreadable, localeUnsupported(String), noAudioFormat, emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unreadable: "The audio file could not be read"
            case .localeUnsupported(let l): "Speech recognition does not support \(l)"
            case .noAudioFormat: "No compatible audio format for transcription"
            case .emptyTranscript: "No speech was recognized in this recording"
            }
        }
    }

    func transcribe(
        fileURL: URL,
        locale: Locale,
        contextualStrings: [String],
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws -> String {
        guard let file = try? AVAudioFile(forReading: fileURL) else {
            throw FileTranscriberError.unreadable
        }

        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw FileTranscriberError.localeUnsupported(locale.identifier)
        }
        try await AudioTranscriber.ensureAssets(locale: supported)

        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let context = AnalysisContext()
        if !contextualStrings.isEmpty {
            context.contextualStrings = [.general: contextualStrings]
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: inputSequence, modules: [transcriber], analysisContext: context)

        // Collect finalized segments only — volatile results are superseded.
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: file.processingFormat),
              let converter = AVAudioConverter(from: file.processingFormat, to: analyzerFormat) else {
            throw FileTranscriberError.noAudioFormat
        }

        let chunkFrames: AVAudioFrameCount = 8192
        let totalFrames = file.length
        var framesRead: Int64 = 0
        while file.framePosition < totalFrames {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            framesRead += Int64(buffer.frameLength)
            if let converted = Self.convert(buffer: buffer, with: converter, to: analyzerFormat) {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
            onProgress(Double(framesRead) / Double(max(totalFrames, 1)))
        }
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same conversion shape as AudioTranscriber.convert (nonisolated, local captures only).
    private nonisolated static func convert(
        buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? out : nil
    }
}
