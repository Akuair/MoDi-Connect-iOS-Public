import AVFoundation
import CoreMedia
import Foundation

enum PCMConverterError: LocalizedError {
    case missingFormat
    case unsupportedFormat
    case copyFailed(OSStatus)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFormat: "捕获帧缺少音频格式"
        case .unsupportedFormat: "无法创建 PCM 转换器"
        case .copyFailed(let status): "读取捕获 PCM 失败（\(status)）"
        case .conversionFailed(let message): "PCM 转换失败：\(message)"
        }
    }
}

/// Converts whatever linear PCM ScreenCaptureKit supplies into 48 kHz mono PCM16LE.
/// The AVAudioConverter is retained until the source format changes.
final class PCMConverter {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var sourceBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?

    init(config: AudioConfig = .default) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: true
        )!
    }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { throw PCMConverterError.missingFormat }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)

        let inputFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inputFrames > 0 else { return Data() }
        if !sameFormat(inputFormat, sourceFormat) { reset() }
        if sourceBuffer == nil || sourceBuffer!.frameCapacity < inputFrames {
            sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrames)
        }
        guard let source = sourceBuffer else { throw PCMConverterError.unsupportedFormat }
        source.frameLength = inputFrames

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(inputFrames),
            into: source.mutableAudioBufferList
        )
        guard copyStatus == noErr else { throw PCMConverterError.copyFailed(copyStatus) }

        if converter == nil || !sameFormat(inputFormat, sourceFormat) {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            converter?.downmix = true
            inputFormat = sourceFormat
            MoDiLogger.audio.info(
                "Capture format: \(sourceFormat.sampleRate, privacy: .public) Hz, \(sourceFormat.channelCount, privacy: .public) ch"
            )
        }
        guard let converter else { throw PCMConverterError.unsupportedFormat }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputFrames) * ratio) + 64)
        if outputBuffer == nil || outputBuffer!.frameCapacity < capacity {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        }
        guard let output = outputBuffer else { throw PCMConverterError.unsupportedFormat }
        output.frameLength = 0

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error {
            throw PCMConverterError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0, let bytes = output.audioBufferList.pointee.mBuffers.mData else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }

    func reset() {
        converter = nil
        inputFormat = nil
        sourceBuffer = nil
        outputBuffer = nil
    }

    private func sameFormat(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}

