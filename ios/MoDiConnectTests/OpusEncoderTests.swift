import Foundation
import XCTest
@testable import MoDiConnect

final class OpusEncoderTests: XCTestCase {
    func testOneSecondBatchProducesFiftyDecodableProtocolPackets() throws {
        let config = AudioConfig.default
        let samples = (0..<(config.frameSamples * 50)).map { index -> Int16 in
            Int16(sin(2 * Double.pi * 1_000 * Double(index) / config.sampleRate) * 12_000)
        }
        let pcm = samples.withUnsafeBytes { Data($0) }
        let assembler = PCMFrameAssembler()
        let encoder = try OpusEncoder(config: config)
        let codec = CompatibleMoDiProtocolAdapter()
        var sequence = PacketSequence()
        let frames = assembler.append(pcm)
        XCTAssertEqual(frames.count, 50)
        for (index, frame) in frames.enumerated() {
            let payload = try encoder.encode(frame)
            let packet = MoDiPacket(type: .audio, linkType: HandshakeManager.wifiLANLinkType,
                                    sequence: sequence.next(), payload: payload)
            let decoded = try codec.decode(codec.encode(packet))
            XCTAssertEqual(decoded.type, .audio)
            XCTAssertEqual(decoded.linkType, HandshakeManager.wifiLANLinkType)
            XCTAssertEqual(decoded.sequence, UInt32(index))
            XCTAssertEqual(decoded.payload, payload)
            XCTAssertEqual(OpusEncoder.decodedSampleCountForTest(decoded.payload), Int32(config.frameSamples))
        }
        XCTAssertEqual(assembler.pendingByteCount, 0)
        XCTAssertEqual(sequence.value, 50)
    }

    func testOneKilohertzFrameRoundTripsThroughLibopus() throws {
        let config = AudioConfig.default
        let samples = (0..<config.frameSamples).map { index -> Int16 in
            let value = sin(2 * Double.pi * 1_000 * Double(index) / config.sampleRate)
            return Int16(value * 12_000)
        }
        let pcm = samples.withUnsafeBytes { Data($0) }

        let encoded = try OpusEncoder(config: config).encode(pcm)

        XCTAssertFalse(encoded.isEmpty)
        XCTAssertLessThan(encoded.count, 4_000)
        XCTAssertEqual(OpusEncoder.decodedSampleCountForTest(encoded), Int32(config.frameSamples))
    }
}
