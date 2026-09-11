import XCTest
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
