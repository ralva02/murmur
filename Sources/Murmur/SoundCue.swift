@preconcurrency import AVFAudio
import Foundation

/// Subtle audio cues. A soft, low hum marks the start of dictation so you
/// know the mic is live without looking at the pill.
@MainActor
enum SoundCue {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static var humBuffer: AVAudioPCMBuffer?

    static func playStartHum() {
        if engine == nil { setUp() }
        guard let engine, let player, let humBuffer else { return }
        if !engine.isRunning { try? engine.start() }
        player.stop()
        player.scheduleBuffer(humBuffer, at: nil)
        player.play()
    }

    private static func setUp() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // ~180 ms soft hum: G3 sine + a whisper of its octave, sine envelope
        // (no attack click, no tail), very low gain.
        let sampleRate = 44100.0
        let duration = 0.18
        let frames = AVAudioFrameCount(duration * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return }
        buffer.frameLength = frames
        let base = 196.0   // G3
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            let envelope = sin(.pi * t / duration)
            let wave = sin(2 * .pi * base * t) * 0.8 + sin(2 * .pi * base * 2 * t) * 0.2
            let sample = Float(wave * envelope) * 0.16
            left[i] = sample
            right[i] = sample
        }

        humBuffer = buffer
        self.engine = engine
        self.player = player
        try? engine.start()
    }
}
