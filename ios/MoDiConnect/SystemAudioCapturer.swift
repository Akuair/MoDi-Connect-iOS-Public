import CoreMedia
import Foundation
#if !targetEnvironment(simulator)
import ScreenCaptureKit
#endif

enum SystemAudioCaptureError: LocalizedError {
    case cancelled
    case pickerFailed(String)
    case requiresPhysicalDevice

    var errorDescription: String? {
        switch self {
        case .cancelled: "用户取消了系统音频捕获"
        case .pickerFailed(let message): "系统捕获失败：\(message)"
        case .requiresPhysicalDevice: "系统音频捕获需要 iOS 27 实体 iPhone；当前模拟器 SDK 不包含 ScreenCaptureKit"
        }
    }
}

#if targetEnvironment(simulator)
/// No fake audio or successful capture state on unsupported simulators.
final class SystemAudioCapturer {
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: ((Error?) -> Void)?

    init(sampleQueue: DispatchQueue) {}

    @MainActor
    func requestFullDisplayCapture() {
        onStopped?(SystemAudioCaptureError.requiresPhysicalDevice)
    }

    func stop() {}
}
#else
/// iOS 27 ScreenCaptureKit capture. Video output is discarded;
/// only `.audio` sample buffers enter the audio pipeline.
final class SystemAudioCapturer: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStarted: (() -> Void)?
    var onStopped: ((Error?) -> Void)?

    private let sampleQueue: DispatchQueue
    private var stream: SCStream?
    private var stopping = false

    init(sampleQueue: DispatchQueue) {
        self.sampleQueue = sampleQueue
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
        self.stream = nil
        Task { [weak self] in
            do { try await stream.stopCapture() }
            catch { MoDiLogger.debug(error.localizedDescription, logger: MoDiLogger.audio) }
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
        guard !stopping else { return }
        if let existing = stream {
            self.stream = nil
            try? await existing.stopCapture()
        }
        guard !stopping else { return }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            self.stream = newStream
            try await newStream.startCapture()
            guard self.stream === newStream, !stopping else { return }
            onStarted?()
        } catch {
            guard self.stream === newStream else { return }
            self.stream = nil
            onStopped?(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, type == .audio, sampleBuffer.isValid else { return }
        onAudio?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard self.stream === stream else { return }
        self.stream = nil
        if !stopping { onStopped?(error) }
    }
}
#endif

