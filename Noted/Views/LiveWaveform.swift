import SwiftUI

/// A scrolling bar waveform that moves with the sound Noted is hearing.
struct LiveWaveform: View {
    let levels: AudioLevels
    let speaker: Speaker
    var bars = 20
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var maxHeight: CGFloat = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            let values = levels.snapshot(speaker, count: bars)
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(speaker.tint.opacity(0.35 + 0.65 * Double(value)))
                        .frame(width: barWidth, height: max(barWidth, CGFloat(value) * maxHeight))
                }
            }
            .frame(height: maxHeight)
            .animation(.linear(duration: 0.05), value: values)
        }
        .accessibilityElement()
        .accessibilityLabel("\(speaker.label) audio level")
    }
}

/// "You" and "Others" meters shown in the header while recording.
struct ListeningIndicator: View {
    let levels: AudioLevels
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 16) {
            meter(.me, icon: "mic.fill")
            meter(.others, icon: "speaker.wave.2.fill")
        }
        .help("Live audio: your microphone and the call audio. If a meter stays flat, Noted can't hear that side.")
    }

    private func meter(_ speaker: Speaker, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(speaker.tint)
            if !compact {
                Text(speaker.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            LiveWaveform(levels: levels, speaker: speaker, bars: compact ? 8 : 16, maxHeight: 18)
        }
    }
}

extension Speaker {
    /// Colour used for this speaker across the app.
    var tint: Color { self == .me ? .accentColor : .orange }
}
