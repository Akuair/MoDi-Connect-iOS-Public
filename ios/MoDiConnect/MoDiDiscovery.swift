import Foundation
import Network

struct MoDiDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let host: NWEndpoint.Host?
    let port: NWEndpoint.Port?
    var handshakePort: NWEndpoint.Port = NWEndpoint.Port(rawValue: 12_347)!

    var address: String { host.map { String(describing: $0) } ?? "正在解析地址…" }
    var portNumber: UInt16 { port?.rawValue ?? 12_345 }
}

final class MoDiDiscovery {
    static let serviceType = "_modi._udp"

    var onDevicesChanged: (([MoDiDevice]) -> Void)?
    var onError: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "com.modi.connect.discovery")
    private var browser: NWBrowser?
    private var devices: [String: MoDiDevice] = [:]
    private var resolvers: [String: NWConnection] = [:]
    private var generation = UUID()
    private var retries = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.startBrowser()
        }
    }

    func restart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopBrowser()
            self.retries = 0
            self.startBrowser()
        }
    }

    private func startBrowser() {
        guard browser == nil else { return }
        let generation = self.generation
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation else { return }
            switch state {
            case .ready: self.onError?(nil)
            case .failed(let error), .waiting(let error):
                self.onError?(Self.discoveryError(error))
                if case .dns(-65569) = error, self.retries < 2 {
                    self.retries += 1
                    self.stopBrowser()
                    let retryGeneration = self.generation
                    self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.generation == retryGeneration else { return }
                        self.startBrowser()
                    }
                }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.generation == generation else { return }
            self.replace(with: results)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in self?.stopBrowser() }
    }

    private func stopBrowser() {
        generation = UUID()
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
        for id in Array(resolvers.keys) where !live.contains(id) {
            resolvers.removeValue(forKey: id)?.cancel()
        }
        for (id, name, endpoint) in serviceResults where resolvers[id] == nil {
            if devices[id] == nil { devices[id] = MoDiDevice(id: id, name: name, host: nil, port: nil) }
            resolve(id: id, name: name, endpoint: endpoint)
        }
        publish()
    }

    private func resolve(id: String, name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .udp)
        resolvers[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.resolvers[id] === connection else { return }
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

    static func discoveryError(_ error: NWError) -> String {
        switch error {
        case .dns(-65569):
            return "Bonjour 与 iOS 系统发现服务的连接失效（DNS -65569），已尝试重建。可点重新发现，或用 IP + 端口连接；这不表示电脑拒绝连接。"
        case .dns(-65570):
            return "本地网络发现被系统策略拒绝（DNS -65570）。请检查系统设置中的本地网络权限。"
        default: return "设备发现：\(error)。可重试发现或手动输入 IP 和端口。"
        }
    }
}

