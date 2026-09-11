import Foundation

struct PacketSequence {
    private(set) var value: UInt32 = 0

    mutating func next() -> UInt32 {
        defer { value &+= 1 }
        return value
    }

    mutating func reset() { value = 0 }
}
