import Foundation
import Network

@MainActor
final class ConnectionManager {
    var onState: ((ConnectionState) -> Void)?
    var onMetrics: ((StreamingMetrics) -> Void)?

    private let protocolAdapter: any MoDiProtocolAdapter
    private let handshake: HandshakeManager
    private let pipeline: AudioPipeline
    private var device: MoDiDevice?
    private(set) var session: MoDiSession?
    private var reconnectTask: Task<Void, Never>?

    init(
        config: AudioConfig = .default,
        protocolAdapter: any MoDiProtocolAdapter = CompatibleMoDiProtocolAdapter()
    ) {
        self.protocolAdapter = protocolAdapter
        handshake = HandshakeManager(protocolAdapter: protocolAdapter)
        pipeline = AudioPipeline(config: config, protocolAdapter: protocolAdapter)
        pipeline.onCaptureStarted = { [weak self] in Task { @MainActor in self?.onState?(.streaming) } }
        pipeline.onStopped = { [weak self] error in
            Task { @MainActor in
                if let error { self?.onState?(.failed(error.localizedDescription)) }
                else { self?.onState?(.connected) }
            }
        }
        pipeline.onMetrics = { [weak self] metrics in Task { @MainActor in self?.onMetrics?(metrics) } }
        pipeline.onNetworkFailure = { [weak self] error in
            MoDiLogger.debug(error.localizedDescription, logger: MoDiLogger.network)
            Task { @MainActor in self?.recover() }
        }
    }

    func connect(to device: MoDiDevice) async {
        guard let host = device.host else {
            onState?(.failed("Bonjour 地址尚未解析"))
            return
        }
        let session = MoDiSession.speakerOnly()
        self.device = device
        onState?(.handshaking)
        do {
            try await handshake.handshake(host: host, port: device.handshakePort, session: session)
            self.session = session
            MoDiLogger.debug("Connected SpeakerOnly session \(session.id)", logger: MoDiLogger.handshake)
            onState?(.connected)
        } catch {
            self.session = nil
            onState?(.failed("连接 \(device.address) 握手 UDP \(device.handshakePort.rawValue) 失败：\(error.localizedDescription)。确认 Windows 使用 LAN 模式、IP/端口正确，并允许 MoDi 通过防火墙。"))
        }
    }

    func startStreaming() async {
        guard session != nil, let device, let host = device.host, let port = device.port else {
            onState?(.failed("未连接 Windows 设备"))
            return
        }
        onState?(.startingCapture)
        do { try await pipeline.start(host: host, audioPort: port) }
        catch { onState?(.failed(error.localizedDescription)) }
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        onState?(.stopping)
        pipeline.stop()
        session = nil
        device = nil
        onState?(.idle)
    }

    private func recover() {
        guard reconnectTask == nil, let device, let host = device.host else { return }
        pipeline.stop()
        onState?(.reconnecting)
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...5 {
                if Task.isCancelled { return }
                let newSession = MoDiSession.speakerOnly()
                do {
                    try await handshake.handshake(host: host, port: device.handshakePort, session: newSession)
                    session = newSession
                    reconnectTask = nil
                    await startStreaming()
                    return
                } catch {
                    if attempt < 5 { try? await Task.sleep(for: .seconds(2)) }
                }
            }
            reconnectTask = nil
            onState?(.failed("原电脑无法恢复，请重新选择"))
        }
    }
}

