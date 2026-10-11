import Foundation
import AVFoundation
import Speech

/// Live, on-device speech-to-text for one audio stream, using Apple's
/// SpeechAnalyzer / SpeechTranscriber (macOS 26).
final class LiveTranscriber {
    let speaker: Speaker

    /// Called on the main actor with (speaker, text, isFinal).
    /// Non-final ("volatile") text is a best guess that gets replaced;
    /// final text is settled and becomes a transcript segment.
    var onUpdate: (@MainActor (Speaker, String, Bool) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?

    init(speaker: Speaker) {
        self.speaker = speaker
    }

    /// Picks the supported transcription language closest to the Mac's language.
    static func preferredLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        if let exact = supported.first(where: { $0.identifier(.bcp47) == current.identifier(.bcp47) }) {
            return exact
        }
        if let language = current.language.languageCode {
            let sameLanguage = supported.filter { $0.language.languageCode == language }
            if let usEnglish = sameLanguage.first(where: { $0.identifier(.bcp47) == "en-US" }) {
                return usEnglish
            }
            if let first = sameLanguage.first {
                return first
            }
        }
        return Locale(identifier: "en-US")
    }

    func start(locale: Locale) async throws {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        // Downloads the on-device speech model the first time it is needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation

        let speaker = self.speaker
        let onUpdate = self.onUpdate
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    guard let onUpdate else { continue }
                    await MainActor.run {
                        onUpdate(speaker, text, isFinal)
                    }
                }
            } catch {
                // The results stream ends with an error if analysis is cancelled; nothing to do.
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
    }

    /// Feeds captured audio in. Called from the audio capture queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation = inputContinuation, let format = analyzerFormat else { return }
        guard let converted = convert(buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Stops accepting audio and waits for the last words to be finalized.
    func finish() async {
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
    }

    /// Abandons transcription without waiting (used when starting fails).
    func cancel() {
        inputContinuation?.finish()
        inputContinuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
