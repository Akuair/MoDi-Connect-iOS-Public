import XCTest
@testable import MoDiConnect

final class PCMFrameAssemblerTests: XCTestCase {
    func testLargeCaptureBatchesNeverDiscardCompleteFrames() {
        // 200 ms / 500 ms / 1 second callbacks exceed the removed 7-frame pacer.
        // Verify actual production assembler output, not a separate timing model.
        for frameCount in [10, 25, 50] {
            let assembler = PCMFrameAssembler()
            let input = Data((0..<(frameCount * 1_920 + 318)).map { UInt8(truncatingIfNeeded: $0) })
            let frames = assembler.append(input)
            XCTAssertEqual(frames.count, frameCount)
            XCTAssertTrue(frames.allSatisfy { $0.count == 1_920 })
            XCTAssertEqual(Data(frames.joined()), Data(input.prefix(frameCount * 1_920)))
            XCTAssertEqual(assembler.pendingByteCount, 318)
            let tail = Data(repeating: 0xA5, count: 1_920 - 318)
            let remainder = assembler.append(tail)
            XCTAssertEqual(remainder, [Data(input.suffix(318)) + tail])
            XCTAssertEqual(assembler.pendingByteCount, 0)
        }
    }

    func testCapturePauseDoesNotInsertSilenceOrDiscardPartialPCM() {
        let assembler = PCMFrameAssembler()
        let prefix = Data(repeating: 0x55, count: 640)
        XCTAssertTrue(assembler.append(prefix).isEmpty)
        for _ in 0..<200 { XCTAssertTrue(assembler.append(Data()).isEmpty) }
        XCTAssertEqual(assembler.pendingByteCount, 640)
        let suffix = Data(repeating: 0xAA, count: 1_280)
        XCTAssertEqual(assembler.append(suffix), [prefix + suffix])
        assembler.reset()
        XCTAssertTrue(assembler.append(Data()).isEmpty)
        XCTAssertEqual(assembler.pendingByteCount, 0)
    }

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
