import Foundation
import Network

struct MoDiDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let host: NWEndpoint.Host?
    let port: NWEndpoint.Port?

    var address: String { host.map { String(describing: $0) } ?? "正在解析地址…" }
    var portNumber: UInt16 { port?.rawValue ?? 12_345 }
}

final class MoDiDiscovery {
    static let serviceType = "_modi._udp"

    var onDevicesChanged: (([MoDiDevice]) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.modi.connect.discovery")
    private var browser: NWBrowser?
    private var devices: [String: MoDiDevice] = [:]
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onError?(error.localizedDescription) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.replace(with: results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        devices.removeAll()
        publish()
    }

    private func replace(with results: Set<NWBrowser.Result>) {
        let serviceResults = results.compactMap { result -> (String, String, NWEndpoint)? in
            guard case .service(let name, _, let domain, _) = result.endpoint else { return nil }
            return ("\(name).\(domain)", name, result.endpoint)
        }
        let live = Set(serviceResults.map(\.0))
        devices = devices.filter { live.contains($0.key) }
        for (id, name, endpoint) in serviceResults where resolvers[id] == nil {
            devices[id] = MoDiDevice(id: id, name: name, host: nil, port: nil)
            resolve(id: id, name: name, endpoint: endpoint)
        }
        publish()
    }

    private func resolve(id: String, name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .udp)
        resolvers[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    self.devices[id] = MoDiDevice(id: id, name: name, host: host, port: port)
                    MoDiLogger.discovery.info("Found \(name, privacy: .public) at \(String(describing: host), privacy: .public):\(port.rawValue)")
                    self.publish()
                }
                connection.cancel()
                self.resolvers[id] = nil
            case .failed, .cancelled:
                self.resolvers[id] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        onDevicesChanged?(devices.values.sorted { $0.name < $1.name })
    }
}
