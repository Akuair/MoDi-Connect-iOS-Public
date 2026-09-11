import Foundation

enum MoDiPacketType: UInt8, Sendable {
    case hello = 1
    case helloAck = 2
    case helloNack = 3
    case route = 4
    case routeAck = 5
    case audio = 6
    case data = 7
}

struct MoDiPacket: Sendable {
    let type: MoDiPacketType
    let linkType: UInt8
    let sequence: UInt32
    let payload: Data
}

enum MoDiProtocolError: LocalizedError {
    case malformedPacket

    var errorDescription: String? {
        switch self {
        case .malformedPacket:
            "MoDi Protocol 数据包无效"
        }
    }
}

protocol MoDiProtocolAdapter: Sendable {
    func encode(_ packet: MoDiPacket) throws -> Data
    func decode(_ data: Data) throws -> MoDiPacket
}

/// Independent interoperability implementation, checked against the bundled 0.1.1
/// .NET public codec. Package version 0.1.1 uses wire version 2, not version 1.
struct CompatibleMoDiProtocolAdapter: MoDiProtocolAdapter {
    private static let prefix: [UInt8] = [0x4c, 0x41, 0x42, 0x42, 0x02]

    func encode(_ packet: MoDiPacket) throws -> Data {
        guard packet.payload.count <= Int(Int32.max) else {
            throw MoDiProtocolError.malformedPacket
        }
        var output = Data(capacity: 15 + packet.payload.count)
        output.append(contentsOf: Self.prefix)
        output.append(packet.type.rawValue)
        output.append(packet.linkType)
        for value in [packet.sequence, UInt32(packet.payload.count)] {
            output.append(UInt8(truncatingIfNeeded: value >> 24))
            output.append(UInt8(truncatingIfNeeded: value >> 16))
            output.append(UInt8(truncatingIfNeeded: value >> 8))
            output.append(UInt8(truncatingIfNeeded: value))
        }
        output.append(packet.payload)
        return output
    }

    func decode(_ data: Data) throws -> MoDiPacket {
        guard data.count >= 15 else { throw MoDiProtocolError.malformedPacket }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.prefix(5).elementsEqual(Self.prefix),
                  let type = MoDiPacketType(rawValue: bytes[5]) else {
                throw MoDiProtocolError.malformedPacket
            }
            func readUInt32(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[offset + $1]) }
            }
            let length = readUInt32(11)
            guard length <= UInt32(Int32.max), Int(length) == data.count - 15 else {
                throw MoDiProtocolError.malformedPacket
            }
            return MoDiPacket(type: type, linkType: bytes[6], sequence: readUInt32(7),
                              payload: Data(bytes.dropFirst(15)))
        }
    }
}

enum HelloSessionPayload {
    static func encode(route: UInt8, sessionID: UUID) -> Data {
        precondition(route <= 3)
        var payload = Data([route])
        var bytes = sessionID.uuid
        withUnsafeBytes(of: &bytes) { payload.append(contentsOf: $0) }
        return payload
    }

    /// Android accepts any valid echoed route and authenticates the ACK by session UUID.
    static func matchesAck(_ payload: Data, sessionID: UUID) -> Bool {
        guard payload.count == 17, let route = payload.first, route <= 3 else { return false }
        return payload.dropFirst() == encode(route: route, sessionID: sessionID).dropFirst()
    }
}
