import Foundation

enum OpusEncoderError: LocalizedError {
    case initialization(Int32)
    case invalidFrame(Int)
    case encoding(Int32)

    var errorDescription: String? {
        switch self {
        case .initialization(let code): "libopus encoder 初始化失败（\(code)）"
        case .invalidFrame(let count): "PCM 帧必须为 1920 bytes，实际为 \(count)"
        case .encoding(let code): "libopus 编码失败（\(code)）"
        }
    }
}

final class OpusEncoder {
    private let config: AudioConfig
    private var encoder: OpaquePointer?
    private var output = [UInt8](repeating: 0, count: 4_000)

    init(config: AudioConfig = .default) throws {
        self.config = config
        var error: Int32 = 0
        encoder = modi_opus_encoder_create(
            Int32(config.sampleRate), Int32(config.channels), Int32(config.bitrate),
            Int32(config.complexity), config.useFEC ? 1 : 0,
            Int32(config.packetLossPercent), config.useConstrainedVBR ? 1 : 0, &error
        )
        guard encoder != nil, error == 0 else { throw OpusEncoderError.initialization(error) }

        MoDiLogger.debug(
            "Encoder 48000Hz mono 20ms bitrate=\(config.bitrate) FEC=\(config.useFEC) loss=\(config.packetLossPercent)% CVBR=\(config.useConstrainedVBR)",
            logger: MoDiLogger.opus
        )

        // Match Android's warm-up frame; its output is intentionally discarded.
        _ = try encode(Data(count: config.frameBytes))
    }

    deinit { modi_opus_encoder_destroy(encoder) }

    func encode(_ pcm16LE: Data) throws -> Data {
        guard pcm16LE.count == config.frameBytes else {
            throw OpusEncoderError.invalidFrame(pcm16LE.count)
        }
        let capacity = Int32(output.count)
        let input = Self.attenuate(pcm16LE, gain: config.outputGain)
        let count: Int32 = input.withUnsafeBytes { pcm in
            output.withUnsafeMutableBytes { encoded in
                modi_opus_encode(
                    encoder,
                    pcm.bindMemory(to: Int16.self).baseAddress,
                    Int32(config.frameSamples),
                    encoded.bindMemory(to: UInt8.self).baseAddress,
                    capacity
                )
            }
        }
        guard count > 0 else { throw OpusEncoderError.encoding(count) }
        return Data(output.prefix(Int(count)))
    }

    /// Optional headroom for simultaneous Windows playback, not noise suppression.
    /// Default gain is unity and returns the original Data without a copy.
    static func attenuate(_ pcm: Data, gain: Float) -> Data {
        precondition(gain > 0 && gain <= 1 && pcm.count.isMultiple(of: 2))
        guard gain < 1 else { return pcm }
        var output = pcm
        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for index in samples.indices {
                samples[index] = Int16(clamping: Int((Float(samples[index]) * gain).rounded()))
            }
        }
        return output
    }

    static func decodedSampleCountForTest(_ packet: Data, frameSamples: Int = 960) -> Int32 {
        var pcm = [Int16](repeating: 0, count: frameSamples)
        return packet.withUnsafeBytes { encoded in
            pcm.withUnsafeMutableBufferPointer { output in
                modi_opus_decode_once(
                    encoded.bindMemory(to: UInt8.self).baseAddress,
                    Int32(packet.count),
                    output.baseAddress,
                    Int32(frameSamples)
                )
            }
        }
    }
}

