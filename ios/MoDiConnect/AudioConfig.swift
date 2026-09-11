import AVFoundation

struct AudioConfig: Sendable {
    static let `default` = AudioConfig()

    let sampleRate: Double
    let channels: AVAudioChannelCount
    let frameMilliseconds: Int
    let bitrate: Int
    let complexity: Int
    let useFEC: Bool
    let packetLossPercent: Int
    let useConstrainedVBR: Bool

    init(
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1,
        frameMilliseconds: Int = 20,
        bitrate: Int = 128_000,
        complexity: Int = 10,
        useFEC: Bool = true,
        packetLossPercent: Int = 15,
        useConstrainedVBR: Bool = true
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameMilliseconds = frameMilliseconds
        self.bitrate = bitrate
        self.complexity = complexity
        self.useFEC = useFEC
        self.packetLossPercent = packetLossPercent
        self.useConstrainedVBR = useConstrainedVBR
    }

    var frameSamples: Int { Int(sampleRate) * frameMilliseconds / 1_000 }
    var frameBytes: Int { frameSamples * MemoryLayout<Int16>.size }
}
