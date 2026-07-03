@preconcurrency import AVFAudio
import AVFoundation
import Foundation
import MurmurCore

/// Long-form capture: mic via AVAudioEngine and system audio via
/// SystemAudioTap, written to two temp files and merged into one m4a on
/// stop. Degrades to mic-only when the tap is unavailable. Independent of
/// the dictation engines — Fn dictation works while this records.
@MainActor @Observable
final class LongFormRecorder {

    enum RecorderError: LocalizedError {
        case micUnavailable
        var errorDescription: String? { "Microphone is unavailable — check permissions." }
    }

    private let micEngine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private var micURL: URL?
    private var systemURL: URL?
    private(set) var startedAt: Date?
    private(set) var systemAudioActive = false
    var isRecording: Bool { startedAt != nil }
    var onStateChange: (() -> Void)?

    func start() throws {
        guard !isRecording else { return }
        let micFormat = micEngine.inputNode.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0 else { throw RecorderError.micUnavailable }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-longform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.m4a")
        let sys = dir.appendingPathComponent("system.m4a")

        let micFile = try AVAudioFile(forWriting: mic, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: micFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        Self.installWriterTap(on: micEngine, file: micFile)
        micEngine.prepare()
        try micEngine.start()
        micURL = mic

        do {
            try tap.start(writingTo: sys)
            systemAudioActive = true
            systemURL = sys
        } catch {
            Diag.app.notice("system audio tap unavailable: \(String(describing: error), privacy: .public)")
            systemAudioActive = false
            systemURL = nil
        }

        startedAt = Date()
        onStateChange?()
    }

    /// The tap closure runs on the audio thread — formed nonisolated,
    /// captures only locals (same invariant as AudioTranscriber).
    private nonisolated static func installWriterTap(on engine: AVAudioEngine, file: AVAudioFile) {
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
    }

    /// Stops capture and returns the final audio (merged when both sources
    /// ran). The mic track is sacred: any merge/system-track problem falls
    /// back to mic-only rather than losing the recording.
    func stop() async throws -> (url: URL, duration: TimeInterval, micOnly: Bool) {
        guard let started = startedAt, let mic = micURL else { throw RecorderError.micUnavailable }
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        tap.stop()
        let duration = Date().timeIntervalSince(started)
        startedAt = nil
        micURL = nil
        defer { onStateChange?() }

        let systemBytes = systemURL.flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int
        } ?? 0
        if systemAudioActive, let sys = systemURL, systemBytes > 4096 {
            let merged = mic.deletingLastPathComponent().appendingPathComponent("mixed.m4a")
            do {
                try await Self.merge(tracks: [mic, sys], to: merged)
                return (merged, duration, false)
            } catch {
                Diag.app.error("track merge failed, keeping mic-only: \(String(describing: error), privacy: .public)")
            }
        }
        return (mic, duration, true)
    }

    /// Multiple audio tracks in one composition mix down on M4A export.
    private static func merge(tracks: [URL], to output: URL) async throws {
        let composition = AVMutableComposition()
        for url in tracks {
            let asset = AVURLAsset(url: url)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            let range = try await CMTimeRange(start: .zero, duration: asset.load(.duration))
            try compositionTrack?.insertTimeRange(range, of: assetTrack, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw SystemAudioTap.TapError.format
        }
        try await export.export(to: output, as: .m4a)
    }
}
