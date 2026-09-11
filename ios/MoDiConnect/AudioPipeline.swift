import CoreMedia
import Foundation
import Network

struct StreamingMetrics: Equatable {
    var packetRate = 0.0
    var bitrate = 0.0
    var droppedFrames: UInt64 = 0
    var queuedMilliseconds = 0
    var concealedFrames: UInt64 = 0
    var lateTicks: UInt64 = 0
    var maximumCaptureGapMilliseconds = 0.0
}

final class AudioPipeline {
    var onMetrics: ((StreamingMetrics) -> Void)?
    var onCaptureStarted: (() -> Void)?
    var onStopped: ((Error?) -> Void)?
    var onNetworkFailure: ((Error) -> Void)?

    private let config: AudioConfig
    private let protocolAdapter: any MoDiProtocolAdapter
    private let queue = DispatchQueue(label: "com.modi.connect.audio-pipeline", qos: .userInteractive)
    private let capturer: SystemAudioCapturer
    private let converter: PCMConverter
    private let assembler: PCMFrameAssembler
    private let pacer: PCMFramePacer
    private var timer: DispatchSourceTimer?
    private var encoder: OpusEncoder?
    private var transport: UDPTransport?
    private var sequence = PacketSequence()
    private var generation = UUID()
    private var sentPackets: UInt64 = 0
    private var sentBytes: UInt64 = 0
    private var conversionFailures: UInt64 = 0
    private var pendingSends = 0
    private var lastCaptureTime: UInt64?
    private var maxCaptureGap = 0.0
    private var metricsStarted = ContinuousClock().now

    init(config: AudioConfig = .default, protocolAdapter: any MoDiProtocolAdapter) {
        self.config = config
        self.protocolAdapter = protocolAdapter
        assembler = PCMFrameAssembler(frameBytes: config.frameBytes)
        pacer = PCMFramePacer(config: config)
        converter = PCMConverter(config: config)
        capturer = SystemAudioCapturer(sampleQueue: queue)
        // Capture conversion and timer share one serial queue; no extra unbounded
        // queue of retained CMSampleBuffers behind an async forwarding hop.
        capturer.onAudio = { [weak self] buffer in self?.consume(buffer) }
        capturer.onStarted = { [weak self] in self?.onCaptureStarted?() }
        capturer.onStopped = { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.stopProcessing()
                self.onStopped?(error)
            }
        }
    }

    @MainActor
    func start(host: NWEndpoint.Host, audioPort: NWEndpoint.Port) async throws {
        let transport = UDPTransport(label: "com.modi.connect.audio-udp")
        try await transport.connect(host: host, port: audioPort)
        do {
            let encoder = try OpusEncoder(config: config)
            queue.sync {
                stopProcessing()
                self.encoder = encoder
                self.transport = transport
                sequence.reset()
                sentPackets = 0
                sentBytes = 0
                conversionFailures = 0
                maxCaptureGap = 0
                metricsStarted = .now
                let token = generation
                transport.onFailure = { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        guard self.generation == token else { return }
                        self.failNetwork(error)
                    }
                }
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.setEventHandler { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.tick()
                }
                self.timer = timer
                timer.activate() // Not scheduled until enough real PCM arrives.
            }
        } catch {
            transport.close()
            throw error
        }
        capturer.requestFullDisplayCapture()
    }

    @MainActor
    func stop() {
        capturer.stop()
        queue.sync { stopProcessing() }
    }

    private func stopProcessing() {
        generation = UUID()
        timer?.cancel()
        timer = nil
        transport?.close()
        transport = nil
        encoder = nil
        pendingSends = 0
        assembler.reset()
        pacer.reset()
        converter.reset()
        lastCaptureTime = nil
    }

    private func consume(_ sampleBuffer: CMSampleBuffer) {
        guard encoder != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let previous = lastCaptureTime {
            maxCaptureGap = max(maxCaptureGap, Double(now - previous) / 1_000_000)
        }
        lastCaptureTime = now
        do {
            let pcm = try converter.convert(sampleBuffer)
            assembler.append(pcm) { pacer.append($0) }
            if pacer.nextDeadline == nil {
                pacer.startIfReady(now: now)
                scheduleNextTick()
            }
        } catch {
            conversionFailures &+= 1
            if conversionFailures == 1 {
                MoDiLogger.debug(error.localizedDescription, logger: MoDiLogger.audio)
            }
        }
    }

    private func scheduleNextTick() {
        guard let deadline = pacer.nextDeadline else { return }
        timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .milliseconds(1))
    }

    private func tick() {
        guard let encoder, let transport else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let frame = pacer.take(now: now) else { scheduleNextTick(); return }
        // Local completion is NOT receipt/ACK. Do not accumulate unlimited packets
        // on a stuck local socket, or flush stale audio into a new session.
        guard pendingSends < 4 else {
            failNetwork(UDPTransportError.failed("音频发送队列阻塞，正在重新握手"))
            return
        }
        do {
            let opus = try encoder.encode(frame)
            let packet = MoDiPacket(type: .audio, linkType: HandshakeManager.wifiLANLinkType,
                                    sequence: sequence.next(), payload: opus)
            let wire = try protocolAdapter.encode(packet)
            let token = generation
            pendingSends += 1
            try transport.enqueueSend(wire) { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == token else { return }
                    self.pendingSends -= 1
                    if let error { self.failNetwork(error); return }
                    self.sentPackets &+= 1
                    self.sentBytes &+= UInt64(wire.count)
                }
            }
        } catch {
            failNetwork(error)
            return
        }
        publishMetricsIfNeeded()
        scheduleNextTick()
    }

    private func failNetwork(_ error: Error) {
        stopProcessing()
        onNetworkFailure?(error)
    }

    private func publishMetricsIfNeeded() {
        let elapsed = metricsStarted.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 1 else { return }
        let metrics = StreamingMetrics(
            packetRate: Double(sentPackets) / seconds,
            bitrate: Double(sentBytes * 8) / seconds,
            droppedFrames: pacer.droppedFrames,
            queuedMilliseconds: pacer.count * config.frameMilliseconds,
            concealedFrames: pacer.concealedFrames,
            lateTicks: pacer.lateTicks,
            maximumCaptureGapMilliseconds: maxCaptureGap
        )
        onMetrics?(metrics)
        MoDiLogger.debug(
            "localSubmit=\(metrics.packetRate)pps wire=\(metrics.bitrate)bps queue=\(metrics.queuedMilliseconds)ms staleDrops=\(metrics.droppedFrames) silenceFill=\(metrics.concealedFrames) lateTicks=\(metrics.lateTicks) captureGapMax=\(maxCaptureGap)ms conversionFailures=\(conversionFailures) nextSequence=\(sequence.value); no receiver loss/latency feedback",
            logger: MoDiLogger.network
        )
        sentPackets = 0
        sentBytes = 0
        maxCaptureGap = 0
        metricsStarted = .now
    }
}

