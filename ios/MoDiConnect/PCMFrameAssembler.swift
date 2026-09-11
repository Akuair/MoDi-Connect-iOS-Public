import Foundation

final class PCMFrameAssembler {
    private let frameBytes: Int
    private var pending = Data()

    init(frameBytes: Int = AudioConfig.default.frameBytes) {
        precondition(frameBytes > 0)
        self.frameBytes = frameBytes
        pending.reserveCapacity(frameBytes * 2)
    }

    var pendingByteCount: Int { pending.count }

    func append(_ data: Data) -> [Data] {
        var frames: [Data] = []
        append(data) { frames.append($0) }
        return frames
    }

    /// Stream frames to the bounded sender, without allocating an array per callback.
    func append(_ data: Data, onFrame: (Data) -> Void) {
        var offset = data.startIndex
        while offset < data.endIndex {
            let count = min(frameBytes - pending.count, data.endIndex - offset)
            pending.append(data[offset..<(offset + count)])
            offset += count
            if pending.count == frameBytes {
                onFrame(pending)
                pending = Data()
                pending.reserveCapacity(frameBytes)
            }
        }
    }

    func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Audio-queue-only, bounded PCM FIFO and monotonic 20 ms sender clock.
/// Sequence numbers are assigned AFTER this queue; local stale drops cannot
/// create gaps in the Windows jitter buffer or advance the Opus encoder unseen.
final class PCMFramePacer {
    private let frameBytes: Int
    private let startupDelay: UInt64
    let capacity: Int
    private let interval: UInt64
    private let fadeSamples: Int
    private var frames: [Data] = []
    private var lastSample: Int16 = 0
    private var needsFade = false
    private let silence: Data
    private(set) var nextDeadline: UInt64?
    private(set) var droppedFrames: UInt64 = 0
    private(set) var concealedFrames: UInt64 = 0
    private(set) var lateTicks: UInt64 = 0
    var count: Int { frames.count }

    init(config: AudioConfig = .default) {
        frameBytes = config.frameBytes
        startupDelay = UInt64(config.senderBufferMilliseconds) * 1_000_000
        capacity = max(1, config.senderBufferMilliseconds / config.frameMilliseconds + 1) + 4
        interval = UInt64(config.frameMilliseconds) * 1_000_000
        fadeSamples = min(config.frameSamples, Int(config.sampleRate) / 200) // 5 ms
        silence = Data(count: config.frameBytes)
        frames.reserveCapacity(capacity)
    }

    func append(_ frame: Data) {
        precondition(frame.count == frameBytes)
        if frames.count == capacity {
            // ponytail: at most nine frames; a ring adds no useful speed here.
            frames.removeFirst()
            droppedFrames &+= 1
            needsFade = true
        }
        frames.append(frame)
    }

    func startIfReady(now: UInt64) {
        // Delay from first arrival, not just a frame-count threshold: one callback
        // can deliver several frames at once and would bypass a count-only prefill.
        if nextDeadline == nil && !frames.isEmpty { nextDeadline = now + startupDelay }
    }

    func take(now: UInt64) -> Data? {
        guard let due = nextDeadline, now >= due else { return nil }
        if now - due >= interval {
            lateTicks &+= 1
            nextDeadline = now + interval // Never burst-send missed timer ticks.
        } else {
            nextDeadline = due + interval // Small scheduling jitter must not accumulate.
        }

        let missing = frames.isEmpty
        var frame = missing ? silence : frames.removeFirst()
        if missing { concealedFrames &+= 1 }
        // Fade to silence once on starvation, and crossfade back / across local drops.
        // No repeated music and no claim that missing source audio was recovered.
        if needsFade || (missing && lastSample != 0) {
            let previous = Int(lastSample)
            frame.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                let samples = bytes.bindMemory(to: Int16.self)
                for index in 0..<fadeSamples {
                    let weight = index + 1
                    let value = (previous * (fadeSamples - weight) + Int(samples[index]) * weight) / fadeSamples
                    samples[index] = Int16(clamping: value)
                }
            }
        }
        lastSample = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: frameBytes - 2, as: Int16.self) }
        needsFade = missing
        return frame
    }

    func reset() {
        frames.removeAll(keepingCapacity: true)
        nextDeadline = nil
        lastSample = 0
        needsFade = false
        droppedFrames = 0
        concealedFrames = 0
        lateTicks = 0
    }
}

