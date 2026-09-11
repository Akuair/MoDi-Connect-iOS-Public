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
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(pending.prefix(frameBytes))
            pending.removeFirst(frameBytes)
        }
        return frames
    }

    func reset() { pending.removeAll(keepingCapacity: true) }
}
