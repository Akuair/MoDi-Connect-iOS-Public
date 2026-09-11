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

    init(config: AudioConfig = .default) {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: config.sampleRate,
            channels: config.channels,
            interleaved: true
        )!
    }

    func convert(_ sampleBuffer: CMSampleBuffer) throws -> Data {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        else { throw PCMConverterError.missingFormat }

        let inputFrames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard inputFrames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputFrames)
        else { return Data() }
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
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { throw PCMConverterError.unsupportedFormat }

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

    private func sameFormat(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.commonFormat == rhs.commonFormat &&
            lhs.isInterleaved == rhs.isInterleaved
    }
}
