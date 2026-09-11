import XCTest
import AVFoundation
import CoreMedia
@testable import MoDiConnect

final class PCMFrameAssemblerTests: XCTestCase {
    func testArbitraryChunksProduceExactFramesWithoutLossOrDuplication() {
        let frameBytes = 1_920
        let chunks = [100, 500, 300, 1_000, 77, 2_700, 421, 2_000]
        let input = Data((0..<chunks.reduce(0, +)).map { UInt8(truncatingIfNeeded: $0) })
        let assembler = PCMFrameAssembler(frameBytes: frameBytes)
        var offset = 0
        var output = Data()

        for size in chunks {
            output.append(contentsOf: assembler.append(input.subdata(in: offset..<(offset + size))).joined())
            offset += size
        }

        let completeBytes = input.count / frameBytes * frameBytes
        XCTAssertEqual(output, input.prefix(completeBytes))
        XCTAssertEqual(assembler.pendingByteCount, input.count - completeBytes)
        XCTAssertEqual(output.count % frameBytes, 0)
    }
}

final class PCMFramePacerTests: XCTestCase {
    private func frame(_ sample: Int16) -> Data {
        [Int16](repeating: sample, count: 960).withUnsafeBytes { Data($0) }
    }

    func testBurstIsPrefilledAndSentExactlyOnceEvery20ms() {
        let pacer = PCMFramePacer()
        pacer.append(frame(1))
        pacer.startIfReady(now: 0)
        XCTAssertEqual(pacer.nextDeadline, 40_000_000)
        pacer.append(frame(2))
        pacer.append(frame(3))
        pacer.startIfReady(now: 0)
        XCTAssertEqual(pacer.take(now: 40_000_000), frame(1))
        XCTAssertNil(pacer.take(now: 0))
        XCTAssertNil(pacer.take(now: 19_999_999))
        XCTAssertEqual(pacer.take(now: 60_000_000), frame(2))
        XCTAssertEqual(pacer.take(now: 80_000_000), frame(3))
        XCTAssertEqual(pacer.droppedFrames, 0)
    }

    func testLateTimerNeverFlushesCatchUpBurstAndResetClearsSession() {
        let pacer = PCMFramePacer()
        for _ in 0..<3 { pacer.append(frame(1)) }
        pacer.startIfReady(now: 0)
        XCTAssertNotNil(pacer.take(now: 130_000_000))
        XCTAssertEqual(pacer.nextDeadline, 150_000_000)
        XCTAssertNil(pacer.take(now: 130_000_000))
        XCTAssertEqual(pacer.lateTicks, 1)
        pacer.reset()
        XCTAssertNil(pacer.nextDeadline)
        XCTAssertEqual(pacer.count, 0)
        XCTAssertEqual(pacer.lateTicks, 0)
    }

    func testSmallTimerJitterDoesNotAccumulateClockDrift() {
        let pacer = PCMFramePacer()
        for _ in 0..<3 { pacer.append(frame(1)) }
        pacer.startIfReady(now: 0)
        for index in 0..<1_000 {
            pacer.append(frame(1))
            XCTAssertNotNil(pacer.take(now: UInt64(index + 2) * 20_000_000 + 1_000_000))
            XCTAssertEqual(pacer.nextDeadline, UInt64(index + 3) * 20_000_000)
        }
        XCTAssertEqual(pacer.droppedFrames, 0)
        XCTAssertEqual(pacer.concealedFrames, 0)
    }

    func testOverflowBoundedAndNewestAudioRetainedBeforeEncoding() throws {
        let pacer = PCMFramePacer()
        for index in 0..<100 { pacer.append(frame(Int16(index))) }
        XCTAssertEqual(pacer.count, pacer.capacity)
        XCTAssertEqual(pacer.droppedFrames, UInt64(100 - pacer.capacity))
        pacer.startIfReady(now: 0)
        let output = try XCTUnwrap(pacer.take(now: 40_000_000))
        // Past the 5 ms splice ramp, first retained frame is exactly unchanged.
        XCTAssertEqual(output.suffix(2), frame(Int16(100 - pacer.capacity)).suffix(2))
    }

    func testStarvationFadesToSilenceThenFadesInWithoutRepeatingMusic() throws {
        let pacer = PCMFramePacer()
        for _ in 0..<3 { pacer.append(frame(12_000)) }
        pacer.startIfReady(now: 0)
        for index in 0..<3 { _ = pacer.take(now: UInt64(index + 2) * 20_000_000) }
        let fading = try XCTUnwrap(pacer.take(now: 100_000_000))
        XCTAssertEqual(fading.suffix(1_440), Data(count: 1_440))
        let first = fading.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertLessThan(abs(Int(first) - 12_000), 100)
        XCTAssertEqual(pacer.take(now: 120_000_000), Data(count: 1_920))
        pacer.append(frame(12_000))
        let recovered = try XCTUnwrap(pacer.take(now: 140_000_000))
        XCTAssertLessThan(recovered.withUnsafeBytes { Int($0.loadUnaligned(as: Int16.self)) }, 100)
        XCTAssertEqual(recovered.suffix(1_440), frame(12_000).suffix(1_440))
        XCTAssertEqual(pacer.concealedFrames, 2)
    }

    func test80msStartupDelayIsNotBypassedByBatchedCapture() {
        let pacer = PCMFramePacer(config: AudioConfig(senderBufferMilliseconds: 80))
        for _ in 0..<4 { pacer.append(frame(1)) }
        pacer.startIfReady(now: 0)
        XCTAssertEqual(pacer.nextDeadline, 80_000_000)
        pacer.append(frame(1))
        pacer.startIfReady(now: 0)
        XCTAssertNil(pacer.take(now: 0))
        XCTAssertNotNil(pacer.take(now: 80_000_000))
    }

    func testBatchedCaptureWithJitterRemainsContinuousAndOrdered() throws {
        let pacer = PCMFramePacer()
        var expected: Int16 = 0
        var nextBatch = 0
        for millisecond in 0..<6_000 {
            // Three frames each 60 ms, alternately 10 ms early / late.
            let arrival = nextBatch == 0 ? 0 : nextBatch * 60 + (nextBatch.isMultiple(of: 2) ? -10 : 10)
            if millisecond == arrival {
                for value in 0..<3 { pacer.append(frame(Int16(nextBatch * 3 + value))) }
                pacer.startIfReady(now: UInt64(millisecond) * 1_000_000)
                nextBatch += 1
            }
            if let output = pacer.take(now: UInt64(millisecond) * 1_000_000) {
                XCTAssertEqual(output, frame(expected))
                expected += 1
            }
        }
        XCTAssertEqual(pacer.concealedFrames, 0)
        XCTAssertEqual(pacer.droppedFrames, 0)
    }
}

final class PCMConverterTests: XCTestCase {
    private func sampleBuffer(rate: Double, channels: AVAudioChannelCount, frames: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                channels: channels, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<Int(channels) {
            for index in 0..<frames { pcm.floatChannelData![channel][index] = 0.25 }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &buffer), noErr)
        let result = try XCTUnwrap(buffer)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        return result
    }

    func testContinuousMonoConversionPreservesSampleCountAndLevelAcrossBufferReuse() throws {
        let converter = PCMConverter()
        var result = Data()
        for size in [100, 500, 300, 1_000, 77, 2_700, 421, 2_000] {
            result.append(try converter.convert(sampleBuffer(rate: 48_000, channels: 1, frames: size)))
        }
        XCTAssertEqual(result.count, 7_098 * 2)
        result.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) { XCTAssertEqual(Double(sample), 8_192, accuracy: 2) }
        }
    }

    func test44100StereoResamplingAndFormatReset() throws {
        let converter = PCMConverter()
        var bytes = 0
        for _ in 0..<100 {
            bytes += try converter.convert(sampleBuffer(rate: 44_100, channels: 2, frames: 441)).count
        }
        // Stateful sample-rate conversion may retain its filter tail; it must not
        // duplicate each input callback or lose a frame on every callback.
        XCTAssertEqual(Double(bytes / 2), 48_000, accuracy: 128)
        converter.reset()
        let mono = try converter.convert(sampleBuffer(rate: 48_000, channels: 1, frames: 960))
        XCTAssertEqual(mono.count, 1_920)
    }
}

