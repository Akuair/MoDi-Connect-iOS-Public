import Foundation
import AVFoundation
import CoreMedia
import XCTest
@testable import MoDiConnect

final class PCMConverterTests: XCTestCase {
    func testSteadyCaptureReusesBuffersWithoutChangingPCM() throws {
        let pooled = PCMConverter(config: AudioConfig(reuseConversionBuffers: true))
        let baseline = PCMConverter(config: AudioConfig(reuseConversionBuffers: false))
        var firstOutput = Data()
        var firstExpected = Data()
        for index in 0..<100 {
            let input = try sampleBuffer(frames: 960, rate: 48_000, channels: 1, offset: index * 960)
            let actual = try pooled.convert(input)
            let expected = try baseline.convert(input)
            XCTAssertEqual(actual, expected, "callback \(index)")
            XCTAssertEqual(actual.count, 1_920)
            XCTAssertTrue(actual.contains { $0 != 0 })
            if index == 0 { firstOutput = actual; firstExpected = expected }
        }
        XCTAssertEqual(firstOutput, firstExpected, "Returned Data must own its PCM after buffer reuse")
        XCTAssertEqual(pooled.bufferAllocationCount, 2)
        XCTAssertEqual(baseline.bufferAllocationCount, 200)
    }

    func testVariableBatchesAndSourceFormatChangesMatchUnpooledConversion() throws {
        let pooled = PCMConverter(config: AudioConfig(reuseConversionBuffers: true))
        let baseline = PCMConverter(config: AudioConfig(reuseConversionBuffers: false))
        var totalBytes = 0
        for (rate, channels) in [(48_000.0, 1), (44_100.0, 2), (48_000.0, 2), (48_000.0, 1)] {
            var offset = 0
            for count in [960, 100, 500, 300, 1_000, 9_600, 77, 960, 960] {
                let input = try sampleBuffer(frames: count, rate: rate, channels: channels, offset: offset)
                let actual = try pooled.convert(input)
                XCTAssertEqual(actual, try baseline.convert(input), "\(rate) Hz / \(channels) ch / \(count) samples")
                XCTAssertEqual(actual.count % 2, 0)
                totalBytes += actual.count
                offset += count
            }
        }
        XCTAssertGreaterThan(totalBytes, 0)
    }

    func testPauseThenSilenceDoesNotLeakPreviousBufferContents() throws {
        let pooled = PCMConverter(config: AudioConfig(reuseConversionBuffers: true))
        let baseline = PCMConverter(config: AudioConfig(reuseConversionBuffers: false))
        for index in 0..<20 {
            // PTS jumps model a source pause; the converter must not fabricate samples.
            let input = try sampleBuffer(frames: 960, rate: 48_000, channels: 1,
                                         offset: index < 10 ? index * 960 : 480_000 + index * 960,
                                         amplitude: index < 10 ? 0.4 : 0)
            let actual = try pooled.convert(input)
            XCTAssertEqual(actual, try baseline.convert(input))
            XCTAssertEqual(actual.count, 1_920)
            if index >= 11 { XCTAssertTrue(actual.allSatisfy { $0 == 0 }) }
        }
    }

    private func sampleBuffer(frames: Int, rate: Double, channels: Int, offset: Int,
                              amplitude: Double = 0.4) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate,
                                                channels: AVAudioChannelCount(channels)))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(pcm.floatChannelData)
        for channel in 0..<channels {
            for index in 0..<frames {
                data[channel][index] = Float(sin(2 * Double.pi * 1_000 * Double(offset + index) / rate)
                                             * amplitude / Double(channel + 1))
            }
        }
        var result: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, presentationTimeStamp: CMTime(value: Int64(offset), timescale: Int32(rate)),
            packetDescriptions: nil, sampleBufferOut: &result
        )
        XCTAssertEqual(status, noErr)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
        return buffer
    }
}

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
