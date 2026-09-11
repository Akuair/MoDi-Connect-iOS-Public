import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case cancelled
    case pickerFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "用户取消了系统音频捕获"
        case .pickerFailed(let message): "系统捕获失败：\(message)"
        }
    }
}

/// iOS 27 ScreenCaptureKit capture. Video output is attached at 1 fps and discarded;
/// only `.audio` sample buffers enter the audio pipeline.
final class SystemAudioCapturer: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: ((Error?) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.modi.connect.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var stopping = false

    override init() {
        super.init()
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        configuration.showsCameraControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
    }

    deinit { SCContentSharingPicker.shared.remove(self) }

    @MainActor
    func requestFullDisplayCapture() {
        stopping = false
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        picker.present()
    }

    func stop() {
        stopping = true
        guard let stream else { return }
        Task { [weak self] in
            do { try await stream.stopCapture() }
            catch { self?.onStopped?(error) }
            self?.stream = nil
        }
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor [weak self] in
            await self?.start(filter: filter)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        onStopped?(SystemAudioCaptureError.cancelled)
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onStopped?(SystemAudioCaptureError.pickerFailed(error.localizedDescription))
    }

    @MainActor
    private func start(filter: SCContentFilter) async {
        if let existing = stream {
            try? await existing.stopCapture()
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1_000)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = newStream
            try await newStream.startCapture()
            onStarted?()
        } catch {
            self.stream = nil
            onStopped?(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onAudio?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        self.stream = nil
        if !stopping { onStopped?(error) }
    }
}
