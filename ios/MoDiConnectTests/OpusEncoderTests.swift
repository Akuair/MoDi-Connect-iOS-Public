import Foundation
import XCTest
@testable import MoDiConnect

final class OpusEncoderTests: XCTestCase {
    func testOptionalHeadroomPreservesPCMShapeAndNeverOverflows() throws {
        let values: [Int16] = [.min, -20_000, 0, 20_000, .max]
        let pcm = values.withUnsafeBytes { Data($0) }
        XCTAssertEqual(OpusEncoder.attenuate(pcm, gain: 1), pcm)
        let reduced = OpusEncoder.attenuate(pcm, gain: 0.5)
        let expected: [Int16] = [-16_384, -10_000, 0, 10_000, 16_384]
        XCTAssertEqual(reduced, expected.withUnsafeBytes { Data($0) })
        XCTAssertEqual(pcm, values.withUnsafeBytes { Data($0) })
        let encoder = try OpusEncoder(config: AudioConfig(outputGain: 0.5))
        XCTAssertEqual(OpusEncoder.decodedSampleCountForTest(try encoder.encode(Data(count: 1_920))), 960)
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

