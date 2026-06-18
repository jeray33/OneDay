import AVFoundation

/// Synthesized click / chime for the rewind interaction.
/// Uses AVAudioEngine so it plays even with the silent switch on (playback category).
enum SoundEffects {
    private static let engine = SoundEngine()

    static func tick() { engine.play(.tick) }
    static func settle() { engine.play(.settle) }
    static func warmUp() { engine.start() }
}

private final class SoundEngine {
    enum Voice { case tick, settle }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private lazy var tickBuffer = SoundEngine.makeTone(frequency: 2000, duration: 0.03,
                                                       decay: 90, format: format, amplitude: 0.5)
    private lazy var settleBuffer = SoundEngine.makeTone(frequency: 660, duration: 0.45,
                                                         decay: 7, format: format, amplitude: 0.6)
    private var started = false

    func start() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            started = false
        }
    }

    func play(_ voice: Voice) {
        start()
        guard started else { return }
        let buffer = voice == .tick ? tickBuffer : settleBuffer
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    /// A sine tone with exponential decay envelope.
    private static func makeTone(frequency: Double, duration: Double, decay: Double,
                                 format: AVAudioFormat, amplitude: Float) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            let envelope = exp(-decay * t)
            samples[frame] = Float(sin(2 * .pi * frequency * t) * envelope) * amplitude
        }
        return buffer
    }
}
