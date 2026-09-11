import Foundation

struct MoDiSession: Sendable, Equatable {
    let id: UUID
    let route: UInt8

    static func speakerOnly() -> MoDiSession {
        MoDiSession(id: UUID(), route: 0)
    }
}
