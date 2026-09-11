import Network
import XCTest
@testable import MoDiConnect

final class LANConnectionAddressTests: XCTestCase {
    func testDefaultsAndCustomPortsReachDevice() throws {
        let defaults = try LANConnectionAddress(host: " 192.168.1.100 ")
        XCTAssertEqual(defaults.audioPort, 12345)
        XCTAssertEqual(defaults.handshakePort, 12347)
        let custom = try LANConnectionAddress(host: "192.168.1.100", audioPort: "2345", handshakePort: "2347")
        XCTAssertEqual(custom.device.port?.rawValue, 2345)
        XCTAssertEqual(custom.device.handshakePort.rawValue, 2347)
        XCTAssertNotNil(custom.device.host)
    }

    func testGeneratedQRCodesRoundTripIPv4AndIPv6() throws {
        for host in ["192.168.1.5", "2001:db8::1", "[2001:db8::2]"] {
            let address = try LANConnectionAddress(host: host, audioPort: "2345", handshakePort: "2347")
            XCTAssertEqual(try LANConnectionAddress.parseQR(address.qrText), address)
        }
    }

    func testMalformedAddressesAndPortsAreRejected() {
        for host in ["", "desktop.local", "999.1.1.1", "https://192.168.1.1", "192.168.1.1:12345", "127.0.0.1/path"] {
            XCTAssertThrowsError(try LANConnectionAddress(host: host))
        }
        for port in ["", "0", "65536", "-1", "+1", "1.5", "abc"] {
            XCTAssertThrowsError(try LANConnectionAddress(host: "192.168.1.1", audioPort: port))
            XCTAssertThrowsError(try LANConnectionAddress(host: "192.168.1.1", handshakePort: port))
        }
    }

    func testRejectsAmbiguousOrUnrelatedQRWithoutConnecting() {
        for text in ["https://example.com", "modi://lan?host=192.168.1.1&host=192.168.1.2",
                     "modi://lan?host=192.168.1.1&port=0", "modi://lan?host=192.168.1.1&token=secret",
                     "modi://user@lan?host=192.168.1.1", "modi://lan?host=192.168.1.1#fragment"] {
            XCTAssertThrowsError(try LANConnectionAddress.parseQR(text))
        }
    }

    func testActualWindowsWifiDirectQRHasSpecificExplanation() {
        // QrCodeHelper.BuildQrPayload: no LAN host or ports are provided.
        XCTAssertThrowsError(try LANConnectionAddress.parseQR("MODI://version=1&transport=wifidirect&device=DESKTOP&token=abcd")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Wi-Fi Direct"))
        }
    }

    func testDNSDaemonFailureIsNotReportedAsPermissionDenied() {
        XCTAssertTrue(MoDiDiscovery.discoveryError(.dns(-65569)).contains("连接失效"))
        XCTAssertTrue(MoDiDiscovery.discoveryError(.dns(-65570)).contains("策略拒绝"))
    }

    @MainActor
    func testManualDeviceCanBeSelectedWithoutDiscovery() throws {
        let app = AppState()
        let address = try LANConnectionAddress(host: "192.168.1.23", audioPort: "2345", handshakePort: "2347")
        app.selectManual(address)
        XCTAssertTrue(app.canConnect)
        XCTAssertEqual(app.selectedDevice?.id, address.qrText)
        XCTAssertEqual(app.selectedDevice?.handshakePort.rawValue, 2347)
        app.selectManual(try LANConnectionAddress(host: "192.168.1.24"))
        XCTAssertEqual(app.devices.count, 1)
    }
}

