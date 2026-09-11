import Foundation

enum ConnectionState: Equatable {
    case idle
    case discovering
    case connecting
    case handshaking
    case connected
    case startingCapture
    case streaming
    case reconnecting
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: "空闲"
        case .discovering: "正在发现"
        case .connecting: "正在连接"
        case .handshaking: "正在握手"
        case .connected: "已连接"
        case .startingCapture: "等待系统捕获授权"
        case .streaming: "正在传输"
        case .reconnecting: "正在重连"
        case .stopping: "正在停止"
        case .failed(let message): "失败：\(message)"
        }
    }
}
