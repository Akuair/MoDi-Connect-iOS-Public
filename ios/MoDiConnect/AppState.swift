import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var devices: [MoDiDevice] = []
    @Published private(set) var discoveryMessage: String?
    @Published var selectedDeviceID: String?
    @Published private(set) var metrics = StreamingMetrics()
    @Published var bitrate = 128_000
    @Published var senderBufferMilliseconds = 40
    @Published var outputAttenuationDB = 0
    @Published var debugLogging = false {
        didSet { MoDiLogger.debugEnabled = debugLogging }
    }

    private let discovery = MoDiDiscovery()
    private var connection = ConnectionManager()
    private var manualDevice: MoDiDevice?

    init() {
        bindConnection()
        discovery.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in
                guard let self else { return }
                self.devices = self.mergeDevices(devices)
                if self.selectedDeviceID == nil, self.devices.count == 1 {
                    self.selectedDeviceID = self.devices[0].id
                }
            }
        }
        discovery.onError = { [weak self] message in
            Task { @MainActor in self?.discoveryMessage = message }
        }
    }

    var selectedDevice: MoDiDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    func startDiscovery() {
        guard canConnect else { return }
        state = .discovering
        discovery.start()
    }

    func connectSelected() async {
        guard canConnect, let selectedDevice else { return }
        manualDevice = selectedDevice
        discovery.stop()
        state = .connecting
        await connection.connect(to: selectedDevice)
    }

    func startStreaming() async { await connection.startStreaming() }

    var canConnect: Bool { state == .idle || state == .discovering || isFailure }

    func restartDiscovery() {
        guard canConnect else { return }
        discoveryMessage = nil
        state = .discovering
        discovery.restart()
    }

    func selectManual(_ address: LANConnectionAddress) {
        guard canConnect else { return }
        manualDevice = address.device
        devices = mergeDevices(devices.filter { $0.name != "手动电脑" })
        selectedDeviceID = address.device.id
    }

    private func mergeDevices(_ discovered: [MoDiDevice]) -> [MoDiDevice] {
        guard let manualDevice else { return discovered }
        return [manualDevice] + discovered.filter { $0.id != manualDevice.id }
    }

    func stop() { connection.stop() }

    func applySettings() {
        guard state == .idle || state == .discovering || isFailure else { return }
        connection.stop()
        connection = ConnectionManager(config: AudioConfig(
            bitrate: bitrate, senderBufferMilliseconds: senderBufferMilliseconds,
            outputGain: Float(pow(10.0, Double(outputAttenuationDB) / 20))
        ))
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

