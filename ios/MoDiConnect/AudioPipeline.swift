import CoreMedia
import Foundation
import Network

struct StreamingMetrics: Equatable {
    var packetRate = 0.0
    var bitrate = 0.0
    var droppedFrames: UInt64 = 0
    var latencyMilliseconds = 20.0
}

final class AudioPipeline {
    var onMetrics: ((StreamingMetrics) -> Void)?
    var onCaptureStarted: (() -> Void)?
    var onStopped: ((Error?) -> Void)?
    var onNetworkFailure: ((Error) -> Void)?

    private let config: AudioConfig
    private let protocolAdapter: any MoDiProtocolAdapter
    private let queue = DispatchQueue(label: "com.modi.connect.audio-pipeline", qos: .userInteractive)
    private let capturer = SystemAudioCapturer()
    private let converter: PCMConverter
    private let assembler: PCMFrameAssembler
    private var encoder: OpusEncoder?
    private var transport: UDPTransport?
    private var sequence = PacketSequence()
    private var sentPackets: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var metricsStarted = ContinuousClock().now

    init(config: AudioConfig = .default, protocolAdapter: any MoDiProtocolAdapter) {
        self.config = config
        converter = PCMConverter(config: config)
        self.protocolAdapter = protocolAdapter
        assembler = PCMFrameAssembler(frameBytes: config.frameBytes)

        capturer.onAudio = { [weak self] buffer in self?.consume(buffer) }
        capturer.onStarted = { [weak self] in self?.onCaptureStarted?() }
        capturer.onStopped = { [weak self] error in self?.onStopped?(error) }
    }

    @MainActor
    func start(host: NWEndpoint.Host, audioPort: NWEndpoint.Port) async throws {
        encoder = try OpusEncoder(config: config)
        assembler.reset()
        sequence.reset()
        sentPackets = 0
        sentBytes = 0
        droppedFrames = 0
        metricsStarted = .now

        let transport = UDPTransport(label: "com.modi.connect.audio-udp")
        transport.onFailure = { [weak self] error in self?.onNetworkFailure?(error) }
        try await transport.connect(host: host, port: audioPort)
        self.transport = transport
        capturer.requestFullDisplayCapture()
    }

    func stop() {
        capturer.stop()
        queue.sync {
            transport?.close()
            transport = nil
            encoder = nil
            assembler.reset()
        }
    }

    private func consume(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let pcm = try self.converter.convert(sampleBuffer)
                for frame in self.assembler.append(pcm) {
                    try self.encodeAndSend(frame)
                }
            } catch {
                self.droppedFrames &+= 1
                MoDiLogger.debug(error.localizedDescription, logger: MoDiLogger.audio)
            }
        }
    }

    private func encodeAndSend(_ frame: Data) throws {
        guard let encoder, let transport else { return }
        let opus = try encoder.encode(frame)
        let packet = MoDiPacket(
            type: .audio,
            linkType: HandshakeManager.wifiLANLinkType,
            sequence: sequence.next(),
            payload: opus
        )
        let wire = try protocolAdapter.encode(packet)
        try transport.enqueueSend(wire)
        sentPackets &+= 1
        sentBytes &+= UInt64(wire.count)
        publishMetricsIfNeeded()
    }

    private func publishMetricsIfNeeded() {
        let elapsed = metricsStarted.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 1 else { return }
        let packetRate = Double(sentPackets) / seconds
        let bitrate = Double(sentBytes * 8) / seconds
        let averagePacketBytes = sentPackets == 0 ? 0 : sentBytes / sentPackets
        onMetrics?(StreamingMetrics(
            packetRate: packetRate,
            bitrate: bitrate,
            droppedFrames: droppedFrames,
            latencyMilliseconds: Double(config.frameMilliseconds)
        ))
        MoDiLogger.debug(
            "packets=\(sentPackets) rate=\(packetRate)pps wire=\(bitrate)bps avg=\(averagePacketBytes)B nextSequence=\(sequence.value); protocol has no audio timestamp",
            logger: MoDiLogger.network
        )
        sentPackets = 0
        sentBytes = 0
        metricsStarted = .now
    }
}
