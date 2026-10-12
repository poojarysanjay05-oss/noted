import Foundation
import SwiftData

/// Who was speaking. Noted hears your microphone and your Mac's audio as two
/// separate streams, so it can tell "you" apart from everyone else on the call.
enum Speaker: String, Codable, CaseIterable {
    case me
    case others

    var label: String { self == .me ? "You" : "Others" }
}

@Model
final class Meeting {
    var title: String
    var date: Date
    var duration: TimeInterval
    var notes: String

    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.meeting)
    var segments: [TranscriptSegment] = []

    // Summary (filled in by Apple Intelligence after the meeting)
    var overview: String?
    var keyPoints: [String] = []
    var decisions: [String] = []
    var actionItems: [String] = []
    var summaryError: String?

    /// Short notes condensed from the transcript, a stretch at a time (made
    /// while recording and when summarizing), so long summaries don't start
    /// from scratch.
    var condensedNotes: [String] = []
    /// How many transcript lines (in time order) `condensedNotes` covers.
    var condensedSegmentCount: Int = 0

    /// True while the meeting is still being recorded. Saved meetings are written
    /// as they go, so if Noted quits mid-meeting this marks what to recover.
    var isInProgress: Bool = false

    init(title: String, date: Date, duration: TimeInterval, notes: String) {
        self.title = title
        self.date = date
        self.duration = duration
        self.notes = notes
    }
}

@Model
final class TranscriptSegment {
    var speakerRaw: String
    var text: String
    /// Seconds from the start of the meeting.
    var offset: TimeInterval
    var meeting: Meeting?

    init(speaker: Speaker, text: String, offset: TimeInterval) {
        self.speakerRaw = speaker.rawValue
        self.text = text
        self.offset = offset
    }

    var speaker: Speaker { Speaker(rawValue: speakerRaw) ?? .others }
}

extension Meeting {
    static let defaultTitlePrefix = "Meeting on "

    static func defaultTitle(for date: Date) -> String {
        defaultTitlePrefix + date.formatted(date: .abbreviated, time: .shortened)
    }

    var orderedSegments: [TranscriptSegment] {
        segments.sorted { $0.offset < $1.offset }
    }

    /// The transcript as plain values for the summarizer, in time order.
    var summaryLines: [SummaryLine] {
        orderedSegments.map { SummaryLine(speaker: $0.speaker.label, text: $0.text) }
    }

    /// The transcript as plain values, sorted once. Views show these instead of
    /// the stored segments, so redraws don't re-sort or re-read the database.
    var transcriptLines: [TranscriptLine] {
        orderedSegments.enumerated().map { index, segment in
            TranscriptLine(id: index, speaker: segment.speaker, text: segment.text, offset: segment.offset)
        }
    }

    /// Plain-text transcript, one line per segment, used as input for summaries.
    var transcriptText: String {
        orderedSegments.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
    }

    // MARK: Search

    /// `nil` if the meeting doesn't match. Otherwise a short excerpt showing
    /// where it matched (empty when the title itself matched).
    func searchSnippet(for query: String) -> String? {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return "" }
        func matches(_ text: String) -> Bool { text.localizedStandardContains(query) }

        if matches(title) { return "" }
        let summaryParts = [overview ?? ""] + keyPoints + decisions + actionItems
        if let part = summaryParts.first(where: matches) {
            return Self.excerpt(of: part, around: query)
        }
        if matches(notes) {
            return Self.excerpt(of: notes, around: query)
        }
        if let segment = orderedSegments.first(where: { matches($0.text) }) {
            return "\(segment.speaker.label): " + Self.excerpt(of: segment.text, around: query)
        }
        return nil
    }

    /// A slice of `text` around the first occurrence of `query`.
    static func excerpt(of text: String, around query: String, radius: Int = 40) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(radius * 2))
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var result = String(flat[start..<end])
        if start > flat.startIndex { result = "…" + result }
        if end < flat.endIndex { result += "…" }
        return result
    }

    // MARK: Copy / export

    var hasNotes: Bool {
        !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var markdownHeading: String {
        "# \(title)\n\n_\(date.formatted(date: .long, time: .shortened)) · \(formatDuration(duration))_\n\n"
    }

    /// Summary sections only (overview, key points, decisions, action items), without a heading.
    private var summaryBody: String? {
        guard let overview else { return nil }
        var md = "## Summary\n\n\(overview)\n\n"
        func section(_ heading: String, _ items: [String], bullet: String = "- ") {
            guard !items.isEmpty else { return }
            md += "## \(heading)\n\n" + items.map { bullet + $0 }.joined(separator: "\n") + "\n\n"
        }
        section("Key points", keyPoints)
        section("Decisions", decisions)
        section("Action items", actionItems, bullet: "- [ ] ")
        return md
    }

    /// What "Copy" puts on the clipboard from the Summary tab.
    var summaryMarkdown: String? {
        summaryBody.map { (markdownHeading + $0).trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
    }

    /// What "Copy" puts on the clipboard from the Transcript tab: one line per
    /// segment with its time, ready to paste anywhere.
    var transcriptCopyText: String? {
        guard !segments.isEmpty else { return nil }
        return orderedSegments
            .map { "[\(formatDuration($0.offset))] \($0.speaker.label): \($0.text)" }
            .joined(separator: "\n") + "\n"
    }

    /// What "Copy" puts on the clipboard from the My notes tab.
    var notesCopyText: String? {
        hasNotes ? notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" : nil
    }

    /// Everything: summary, notes and transcript.
    var markdown: String {
        var md = markdownHeading
        if let summaryBody { md += summaryBody }
        if hasNotes {
            md += "## My notes\n\n\(notes)\n\n"
        }
        if !segments.isEmpty {
            md += "## Transcript\n\n"
            md += orderedSegments.map { "**\($0.speaker.label):** \($0.text)" }.joined(separator: "\n\n")
            md += "\n"
        }
        return md
    }
}

/// One transcript line, as a plain value for fast display.
struct TranscriptLine: Identifiable, Hashable {
    let id: Int
    let speaker: Speaker
    let text: String
    let offset: TimeInterval
}

struct NotedError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval.rounded(.down)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
