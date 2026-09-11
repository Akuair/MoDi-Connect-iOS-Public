import Foundation
import Network

struct LANConnectionAddress: Equatable {
    let host: String
    let audioPort: UInt16
    let handshakePort: UInt16

    init(host: String, audioPort: String = "12345", handshakePort: String = "12347") throws {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // Accept literal IPs only: no URL credentials, paths or accidental DNS lookups.
        guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
            throw AddressError.invalidIP
        }
        func port(_ text: String) throws -> UInt16 {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt16(value), number > 0 else { throw AddressError.invalidPort }
            return number
        }
        self.host = host
        self.audioPort = try port(audioPort)
        self.handshakePort = try port(handshakePort)
    }

    /// iOS LAN address-sharing format, NOT a change to the MoDi wire protocol.
    var qrText: String {
        var url = URLComponents()
        url.scheme = "modi"
        url.host = "lan"
        url.queryItems = [URLQueryItem(name: "host", value: host),
                          URLQueryItem(name: "port", value: String(audioPort)),
                          URLQueryItem(name: "handshakePort", value: String(handshakePort))]
        return url.string!
    }

    static func parseQR(_ text: String) throws -> Self {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2048 else { throw AddressError.invalidQR }
        if text.lowercased().hasPrefix("modi://version=") {
            throw AddressError.wifiDirectQR
        }
        guard let url = URLComponents(string: text), url.scheme?.lowercased() == "modi",
              url.host?.lowercased() == "lan", url.path.isEmpty, url.fragment == nil,
              url.user == nil, url.password == nil, url.port == nil else { throw AddressError.invalidQR }
        var values: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard ["host", "port", "handshakePort"].contains(item.name),
                  values[item.name] == nil, let value = item.value else { throw AddressError.invalidQR }
            values[item.name] = value
        }
        guard let host = values["host"] else { throw AddressError.invalidIP }
        return try Self(host: host, audioPort: values["port"] ?? "12345",
                        handshakePort: values["handshakePort"] ?? "12347")
    }

    var device: MoDiDevice {
        MoDiDevice(id: qrText, name: "手动电脑", host: NWEndpoint.Host(host),
                   port: NWEndpoint.Port(rawValue: audioPort),
                   handshakePort: NWEndpoint.Port(rawValue: handshakePort)!)
    }

    enum AddressError: LocalizedError {
        case invalidIP, invalidPort, invalidQR, wifiDirectQR
        var errorDescription: String? {
            switch self {
            case .invalidIP: "请输入电脑的有效 IPv4 或 IPv6 地址，不要输入网址或端口。"
            case .invalidPort: "端口必须为 1–65535 的整数。默认音频 12345，握手 12347。"
            case .invalidQR: "不是支持的 LAN 连接码。请使用本页生成的 modi://lan 二维码，或手动输入电脑 IP。"
            case .wifiDirectQR: "这是 Windows 的 Wi-Fi Direct 配对码，没有 LAN IP/端口。iOS 当前只支持 LAN，请输入电脑的局域网 IP。"
            }
        }
    }
}

