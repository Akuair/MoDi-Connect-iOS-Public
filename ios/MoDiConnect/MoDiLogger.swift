import OSLog

enum MoDiLogger {
    static var debugEnabled = false
    static let discovery = Logger(subsystem: "com.modi.connect.ios", category: "Discovery")
    static let handshake = Logger(subsystem: "com.modi.connect.ios", category: "Handshake")
    static let audio = Logger(subsystem: "com.modi.connect.ios", category: "Audio")
    static let opus = Logger(subsystem: "com.modi.connect.ios", category: "Opus")
    static let network = Logger(subsystem: "com.modi.connect.ios", category: "Network")

    static func debug(_ message: String, logger: Logger) {
        guard debugEnabled else { return }
        logger.debug("\(message, privacy: .public)")
    }
}
