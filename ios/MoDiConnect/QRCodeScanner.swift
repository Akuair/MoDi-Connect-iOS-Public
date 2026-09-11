import AVFoundation
import SwiftUI
import VisionKit

struct QRCodeScanner: UIViewControllerRepresentable {
    var onResult: (Result<String, Error>) -> Void

    func makeUIViewController(context: Context) -> ScannerHost {
        let host = ScannerHost()
        host.onResult = onResult
        return host
    }
    func updateUIViewController(_ controller: ScannerHost, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerHost, coordinator: ()) {
        controller.finish()
    }

    final class ScannerHost: UIViewController, DataScannerViewControllerDelegate {
        var onResult: ((Result<String, Error>) -> Void)?
        private var scanner: DataScannerViewController?
        private var finished = false
        private var started = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !started else { return }
            started = true
            Task { @MainActor [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, !self.finished else { return }
                guard allowed else { self.fail("相机权限未开启，请在系统设置中允许相机访问，或手动连接。"); return }
                guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
                    self.fail("此设备当前无法扫码，请使用手动输入连接。"); return
                }
                let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                        qualityLevel: .balanced, recognizesMultipleItems: false,
                                                        isHighFrameRateTrackingEnabled: false,
                                                        isHighlightingEnabled: true)
                self.scanner = scanner
                scanner.delegate = self
                self.addChild(scanner)
                scanner.view.frame = self.view.bounds
                scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                self.view.addSubview(scanner.view)
                scanner.didMove(toParent: self)
                do { try scanner.startScanning() } catch { self.complete(.failure(error)) }
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            finish()
        }
        func finish() { finished = true; scanner?.stopScanning() }
        private func complete(_ result: Result<String, Error>) {
            guard !finished else { return }
            finish()
            onResult?(result)
        }
        private func fail(_ message: String) {
            complete(.failure(NSError(domain: "MoDiScanner", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message])))
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let text = barcode.payloadStringValue { complete(.success(text)); return }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            complete(.failure(error))
        }
    }
}

