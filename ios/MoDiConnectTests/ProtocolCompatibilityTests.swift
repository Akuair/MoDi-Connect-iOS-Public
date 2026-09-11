import Foundation
import XCTest
@testable import MoDiConnect

final class ProtocolCompatibilityTests: XCTestCase {
    func testSpeakerOnlyHelloPayloadMatchesOpenApplicationContract() {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let payload = HelloSessionPayload.encode(route: 0, sessionID: id)
        XCTAssertEqual(payload.count, 17)
        XCTAssertEqual(payload.first, 0)
        XCTAssertEqual(payload.dropFirst(), Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                                  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]))
        XCTAssertTrue(HelloSessionPayload.matchesAck(payload, sessionID: id))
    }

    func testWireMatchesBundledDotNetCodec() throws {
        let adapter = CompatibleMoDiProtocolAdapter()
        let cases: [(MoDiPacketType, UInt32, String, String)] = [
            (.hello, 0, "0000112233445566778899AABBCCDDEEFF", "4C41424202010100000000000000110000112233445566778899AABBCCDDEEFF"),
            (.helloAck, 0, "0000112233445566778899AABBCCDDEEFF", "4C41424202020100000000000000110000112233445566778899AABBCCDDEEFF"),
            (.audio, 0x12345678, "112233", "4C4142420206011234567800000003112233"),
            (.audio, UInt32.max, "", "4C414242020601FFFFFFFF00000000")
        ]
        for (type, sequence, payload, expected) in cases {
            let packet = MoDiPacket(type: type, linkType: 1, sequence: sequence, payload: hex(payload))
            XCTAssertEqual(try adapter.encode(packet), hex(expected))
            let decoded = try adapter.decode(hex(expected))
            XCTAssertEqual(decoded.type, type)
            XCTAssertEqual(decoded.sequence, sequence)
            XCTAssertEqual(decoded.payload, packet.payload)
        }
    }

    func testRejectsBadFraming() throws {
        let adapter = CompatibleMoDiProtocolAdapter()
        let valid = hex("4C4142420206011234567800000003112233")
        for count in 0..<valid.count {
            XCTAssertThrowsError(try adapter.decode(Data(valid.prefix(count))))
        }
        XCTAssertThrowsError(try adapter.decode(valid + Data([0])))
        for offset in [0, 1, 2, 3, 4, 5, 11, 12, 13, 14] {
            var corrupted = valid
            corrupted[offset] = 0xff
            XCTAssertThrowsError(try adapter.decode(corrupted))
        }
        // The official decoder deliberately does not validate link IDs.
        var unusualLink = valid
        unusualLink[6] = 255
        XCTAssertEqual(try adapter.decode(unusualLink).linkType, 255)
    }

    private func hex(_ string: String) -> Data {
        let chars = Array(string)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
}
