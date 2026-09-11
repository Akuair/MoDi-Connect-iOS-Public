import Foundation
import XCTest
@testable import MoDiConnect

final class DiscoveryIntegrationTests: XCTestCase {
    func testDiscoversResolvedWindowsServiceOnRealLAN() throws {
        guard ProcessInfo.processInfo.environment["MODI_RUN_LAN_TESTS"] == "1" else {
            throw XCTSkip("Set MODI_RUN_LAN_TESTS=1 on a Mac sharing the Windows MoDi LAN.")
        }

        let found = expectation(description: "resolved _modi._udp Windows service")
        let discovery = MoDiDiscovery()
        discovery.onDevicesChanged = { devices in
            if devices.contains(where: { $0.host != nil && $0.port?.rawValue == 12_345 }) {
                found.fulfill()
            }
        }
        discovery.start()
        wait(for: [found], timeout: 20)
        discovery.stop()
    }
}

final class EndToEndIntegrationTests: XCTestCase {
    func testRequiresPhysicalIPhoneSystemPickerAndExistingWindowsRelease() throws {
        throw XCTSkip(
            "Manual hardware acceptance test: iOS 27 iPhone + system picker + same-LAN Windows release + default speaker. See ios/README.md."
        )
    }
}
