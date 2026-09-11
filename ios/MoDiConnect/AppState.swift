import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var devices: [MoDiDevice] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var metrics = StreamingMetrics()
    @Published var bitrate = 128_000
    @Published var debugLogging = false {
        didSet { MoDiLogger.debugEnabled = debugLogging }
    }

    private let discovery = MoDiDiscovery()
    private var connection = ConnectionManager()

    init() {
        bindConnection()
        discovery.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                self?.devices = devices
                if self?.selectedDeviceID == nil, devices.count == 1 {
                    self?.selectedDeviceID = devices[0].id
                }
            }
        }
        discovery.onError = { [weak self] message in
            Task { @MainActor in self?.state = .failed(message) }
        }
    }

    var selectedDevice: MoDiDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func startDiscovery() {
        state = .discovering
        discovery.start()
    }

    func connectSelected() async {
        guard let selectedDevice else { return }
        state = .connecting
        await connection.connect(to: selectedDevice)
    }

    func startStreaming() async { await connection.startStreaming() }

    func stop() { connection.stop() }

    func applySettings() {
        guard state == .idle || state == .discovering || isFailure else { return }
        connection.stop()
        connection = ConnectionManager(config: AudioConfig(bitrate: bitrate))
        bindConnection()
        state = .discovering
    }

    private var isFailure: Bool {
        if case .failed = state { return true }
        return false
    }

    private func bindConnection() {
        connection.onState = { [weak self] newState in self?.state = newState }
        connection.onMetrics = { [weak self] metrics in self?.metrics = metrics }
    }
}
