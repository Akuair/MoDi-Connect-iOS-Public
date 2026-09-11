import Foundation
import Network

struct HandshakeManager {
    static let handshakePort = NWEndpoint.Port(rawValue: 12_347)!
    static let wifiLANLinkType: UInt8 = 1

    let protocolAdapter: any MoDiProtocolAdapter

    func handshake(host: NWEndpoint.Host, session: MoDiSession) async throws {
        let hello = MoDiPacket(
            type: .hello,
            linkType: Self.wifiLANLinkType,
            sequence: 0,
            payload: HelloSessionPayload.encode(route: session.route, sessionID: session.id)
        )
        // Encode the complete datagram before opening the handshake socket.
        let wirePacket = try protocolAdapter.encode(hello)
        for attempt in 1...3 {
            let transport = UDPTransport(label: "com.modi.connect.handshake.\(attempt)")
            defer { transport.close() }
            try await transport.connect(host: host, port: Self.handshakePort)
            try await transport.send(wirePacket)
            MoDiLogger.debug("HELLO attempt \(attempt)/3", logger: MoDiLogger.handshake)
            do {
                let reply = try await transport.receive(
                    timeoutNanoseconds: attempt == 3 ? 500_000_000 : 800_000_000
                )
                let packet = try protocolAdapter.decode(reply)
                guard packet.type == .helloAck,
                      HelloSessionPayload.matchesAck(packet.payload, sessionID: session.id)
                else { throw MoDiProtocolError.malformedPacket }
                MoDiLogger.debug("HELLO_ACK received for session \(session.id)", logger: MoDiLogger.handshake)
                return
            } catch UDPTransportError.timedOut where attempt < 3 {
                transport.close()
                continue
            }
        }
        throw UDPTransportError.timedOut
    }
}
