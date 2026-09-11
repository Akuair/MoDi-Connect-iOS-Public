import Foundation

/// Compile together with the production Swift adapter; output is checked by
/// ProtocolProbe using the actual bundled .NET binary, not a second test codec.
@main
struct CodecCheck {
    static func main() throws {
        let adapter = CompatibleMoDiProtocolAdapter()
        for type in UInt8(1)...7 {
            for length in [0, 1, 17, 255, 256, 320, 4000, 65536] {
                for sequence in [UInt32(0), 1, 0x12345678, UInt32.max] {
                    let payload = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
                    let packet = MoDiPacket(type: MoDiPacketType(rawValue: type)!, linkType: 1,
                                            sequence: sequence, payload: payload)
                    let wire = try adapter.encode(packet)
                    let decoded = try adapter.decode(wire)
                    precondition(decoded.type == packet.type && decoded.sequence == sequence && decoded.payload == payload)
                    print(wire.map { String(format: "%02X", $0) }.joined())
                }
            }
        }
        let valid = try adapter.encode(MoDiPacket(type: .audio, linkType: 1, sequence: 0, payload: Data([1,2,3])))
        var invalid = (0..<valid.count).map { Data(valid.prefix($0)) }
        invalid.append(valid + Data([0]))
        for offset in [0, 1, 2, 3, 4, 5, 11, 12, 13, 14] {
            var bad = valid
            bad[offset] = 255
            invalid.append(bad)
        }
        for bad in invalid {
            do {
                _ = try adapter.decode(bad)
                fatalError("Accepted invalid framing")
            } catch MoDiProtocolError.malformedPacket { }
        }
    }
}
