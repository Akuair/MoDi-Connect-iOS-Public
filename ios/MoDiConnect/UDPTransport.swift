import Foundation
import Network

enum UDPTransportError: LocalizedError {
    case notConnected
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "UDP 尚未连接"
        case .timedOut: "UDP 接收超时"
        case .failed(let message): "UDP 失败：\(message)"
        }
    }
}

final class UDPTransport {
    var onFailure: ((Error) -> Void)?

    private let queue: DispatchQueue
    private var connection: NWConnection?

    init(label: String = "com.modi.connect.udp") {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    func connect(host: NWEndpoint.Host, port: NWEndpoint.Port) async throws {
        close()
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        parameters.serviceClass = .interactiveVoice
        let connection = NWConnection(host: host, port: port, using: parameters)
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume()
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: UDPTransportError.failed(error.localizedDescription))
                    } else {
                        self?.onFailure?(error)
                    }
                case .waiting(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: UDPTransportError.failed(error.localizedDescription))
                        connection.cancel()
                    } else {
                        self?.onFailure?(error)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(throwing: UDPTransportError.timedOut)
                connection.cancel()
            }
        }
    }

    func send(_ data: Data) async throws {
        guard let connection else { throw UDPTransportError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: UDPTransportError.failed(error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    /// Submits a datagram without blocking the realtime audio queue. Calls made by the
    /// serial audio queue retain submission order; Network.framework owns the bytes
    /// until the completion handler fires.
    func enqueueSend(_ data: Data, completion: @escaping (Error?) -> Void) throws {
        guard let connection else { throw UDPTransportError.notConnected }
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    func receive(timeoutNanoseconds: UInt64 = 500_000_000) async throws -> Data {
        guard let connection else { throw UDPTransportError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false
            connection.receiveMessage { data, _, _, error in
                guard !completed else { return }
                completed = true
                if let error { continuation.resume(throwing: UDPTransportError.failed(error.localizedDescription)) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: UDPTransportError.notConnected) }
            }
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
                guard !completed else { return }
                completed = true
                continuation.resume(throwing: UDPTransportError.timedOut)
            }
        }
    }

    func close() {
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    deinit { close() }
}

