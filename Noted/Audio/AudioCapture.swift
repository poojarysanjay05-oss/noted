import Foundation
import AVFoundation
import ScreenCaptureKit

/// Captures two audio streams at once with ScreenCaptureKit:
///  - the Mac's system audio (everyone else on a Zoom / Meet / Teams call)
///  - the microphone (you)
/// No bot joins the meeting; Noted just listens to this Mac.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onSystemAudio: ((AVAudioPCMBuffer) -> Void)?
    var onMicrophone: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.noted.audio-capture")

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw NotedError("Noted needs Screen & System Audio Recording permission to hear the other people on your calls. Turn it on in System Settings → Privacy & Security, then quit and reopen Noted.")
        }
        guard let display = content.displays.first else {
            throw NotedError("No display was found to capture system audio from.")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // We only want audio, so keep the (mandatory) video stream tiny and slow.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .audio:
            if let buffer = sampleBuffer.pcmBuffer() { onSystemAudio?(buffer) }
        case .microphone:
            if let buffer = sampleBuffer.pcmBuffer() { onMicrophone?(buffer) }
        default:
            break // video frames are ignored
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}

extension CMSampleBuffer {
    /// Copies an audio sample buffer into an AVAudioPCMBuffer.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
