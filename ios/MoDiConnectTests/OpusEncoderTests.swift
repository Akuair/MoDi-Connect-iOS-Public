import Foundation
import XCTest
@testable import MoDiConnect

final class OpusEncoderTests: XCTestCase {
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
