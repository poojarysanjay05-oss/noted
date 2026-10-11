import Foundation
import AVFoundation
import Accelerate

/// Recent loudness for each audio stream, used to draw the live waveform.
///
/// Audio arrives on the capture queue many times a second; this keeps only a
/// short rolling history (one value every 50 ms) behind a lock, and the view
/// reads it at screen refresh rate. That keeps the main thread free.
final class AudioLevels: @unchecked Sendable {
    static let historyLength = 32
    private static let interval: CFAbsoluteTime = 0.05

    private let lock = NSLock()
    private var history: [Speaker: [Float]] = [:]
    private var pending: [Speaker: Float] = [:]
    private var lastPush: [Speaker: CFAbsoluteTime] = [:]

    init() { reset() }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        for speaker in Speaker.allCases {
            history[speaker] = Array(repeating: 0, count: Self.historyLength)
            pending[speaker] = 0
            lastPush[speaker] = 0
        }
    }

    /// Called from the audio queue with a 0...1 level.
    func record(_ level: Float, for speaker: Speaker) {
        lock.lock(); defer { lock.unlock() }
        let peak = max(pending[speaker] ?? 0, level)
        pending[speaker] = peak
        let now = CFAbsoluteTimeGetCurrent()
        guard now - (lastPush[speaker] ?? 0) >= Self.interval else { return }
        var values = history[speaker] ?? []
        values.append(peak)
        if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
        history[speaker] = values
        pending[speaker] = 0
        lastPush[speaker] = now
    }

    /// The most recent `count` levels, oldest first. If a stream has gone quiet
    /// (macOS stops sending buffers when nothing is playing) it falls to silence.
    func snapshot(_ speaker: Speaker, count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var values = history[speaker] ?? []
        let idle = CFAbsoluteTimeGetCurrent() - (lastPush[speaker] ?? 0)
        let missed = min(Self.historyLength, Int(idle / Self.interval) - 1)
        if missed > 0 {
            values.append(contentsOf: repeatElement(0, count: missed))
        }
        return Array(values.suffix(count))
    }
}

extension AVAudioPCMBuffer {
    /// Loudness on a 0...1 scale (-50 dB → 0, 0 dB → 1), from the first channel.
    var normalizedLevel: Float {
        guard frameLength > 0, let channel = floatChannelData?[0] else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (decibels + 50) / 50))
    }
}
