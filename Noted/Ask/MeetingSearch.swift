import Foundation
import SwiftData
import NaturalLanguage

/// A piece of one meeting (its summary, your notes, or a stretch of transcript)
/// that can be handed to the language model as evidence.
struct MeetingChunk: Sendable {
    enum Kind: Sendable {
        case summary, notes, transcript

        var name: String {
            switch self {
            case .summary: return "summary"
            case .notes: return "my notes"
            case .transcript: return "transcript"
            }
        }
    }

    let meetingID: PersistentIdentifier
    let meetingTitle: String
    let meetingDate: Date
    let kind: Kind
    let text: String

    /// e.g. "Budget review — 3 Oct 2026 (transcript)"
    var label: String {
        "\(meetingTitle) — \(meetingDate.formatted(date: .abbreviated, time: .shortened)) (\(kind.name))"
    }
}

/// A date range read from the question, like "last week" or "yesterday".
struct TimeFilter {
    let range: DateInterval
    /// How to describe it in a sentence, e.g. "last week".
    let phrase: String
}

/// Finds the parts of your meetings most relevant to a question.
///
/// The on-device model can only read a few pages at once, so instead of giving
/// it every meeting, this ranks small excerpts by matching words and by meaning
/// (Apple's on-device sentence embeddings) and keeps the best ones.
enum MeetingSearch {
    /// Roughly how much text to give the model (about 2,000 tokens).
    static let characterBudget = 6_500
    private static let transcriptChunkSize = 700
    private static let maxChunksPerMeeting = 3
    /// Excerpts scoring below this fraction of the best match are left out.
    private static let relevanceCutoff = 0.6

    // MARK: Breaking meetings into excerpts

    @MainActor
    static func chunks(for meetings: [Meeting]) -> [MeetingChunk] {
        var result: [MeetingChunk] = []
        for meeting in meetings {
            func add(_ kind: MeetingChunk.Kind, _ text: String) {
                result.append(MeetingChunk(
                    meetingID: meeting.persistentModelID,
                    meetingTitle: meeting.title,
                    meetingDate: meeting.date,
                    kind: kind,
                    text: text
                ))
            }

            if let overview = meeting.overview {
                var text = "Overview: \(overview)"
                if !meeting.keyPoints.isEmpty { text += "\nKey points: " + meeting.keyPoints.joined(separator: "; ") }
                if !meeting.decisions.isEmpty { text += "\nDecisions: " + meeting.decisions.joined(separator: "; ") }
                if !meeting.actionItems.isEmpty { text += "\nAction items: " + meeting.actionItems.joined(separator: "; ") }
                add(.summary, text)
            }

            if meeting.hasNotes {
                add(.notes, String(meeting.notes.prefix(transcriptChunkSize * 2)))
            }

            var current = ""
            for segment in meeting.orderedSegments {
                let line = "\(segment.speaker.label): \(segment.text)\n"
                if current.count + line.count > transcriptChunkSize, !current.isEmpty {
                    add(.transcript, current)
                    current = ""
                }
                current += line
            }
            if !current.isEmpty { add(.transcript, current) }
        }
        return result
    }

    // MARK: Dates in the question

    static func timeFilter(in question: String, now: Date = .now, calendar: Calendar = .current) -> TimeFilter? {
        let text = question.lowercased()
        let startOfToday = calendar.startOfDay(for: now)

        if text.contains("today") {
            return TimeFilter(range: DateInterval(start: startOfToday, end: now), phrase: "today")
        }
        if text.contains("yesterday"), let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) {
            return TimeFilter(range: DateInterval(start: start, end: startOfToday), phrase: "yesterday")
        }
        if text.contains("this week"), let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            return TimeFilter(range: week, phrase: "this week")
        }
        if text.contains("last week") || text.contains("previous week"),
           let lastWeekDay = calendar.date(byAdding: .weekOfYear, value: -1, to: now),
           let week = calendar.dateInterval(of: .weekOfYear, for: lastWeekDay) {
            return TimeFilter(range: week, phrase: "last week")
        }
        if text.contains("this month"), let month = calendar.dateInterval(of: .month, for: now) {
            return TimeFilter(range: month, phrase: "this month")
        }
        if text.contains("last month"),
           let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: now),
           let month = calendar.dateInterval(of: .month, for: lastMonthDay) {
            return TimeFilter(range: month, phrase: "last month")
        }
        // "last 10 days", "past 3 days"
        if let match = text.firstMatch(of: #/(?:last|past) (\d+) days?/#),
           let days = Int(match.1),
           let start = calendar.date(byAdding: .day, value: -days, to: startOfToday) {
            return TimeFilter(range: DateInterval(start: start, end: now), phrase: "in the last \(days) days")
        }
        return nil
    }

    // MARK: Ranking

    /// The most relevant excerpts that fit in the model's budget, best first.
    static func select(_ chunks: [MeetingChunk], for question: String) -> [MeetingChunk] {
        let keywords = keywords(in: question)
        let embedding = sentenceEmbedding(for: question)
        let newest = chunks.map(\.meetingDate).max() ?? .now

        let scored: [(chunk: MeetingChunk, score: Double)] = chunks.map { chunk in
            let lower = chunk.text.lowercased()
            let title = chunk.meetingTitle.lowercased()
            var score = 0.0
            for keyword in keywords {
                if lower.contains(keyword) { score += 1 }
                if title.contains(keyword) { score += 0.5 }
            }
            if let embedding {
                let distance = embedding.distance(
                    between: question,
                    and: String(chunk.text.prefix(1_000)),
                    distanceType: .cosine
                )
                score += max(0, 1 - distance) * 3
            }
            if chunk.kind == .summary { score += 0.4 }
            if chunk.kind == .notes { score += 0.2 }
            // A little nudge towards recent meetings when everything else is equal.
            let daysOld = newest.timeIntervalSince(chunk.meetingDate) / 86_400
            score += max(0, 0.3 - daysOld * 0.01)
            return (chunk, score)
        }

        // Only keep excerpts that are a reasonably close match to the best one, so
        // unrelated meetings aren't padded in just because there's room.
        let ranked = scored.sorted(by: { $0.score > $1.score })
        let threshold = (ranked.first?.score ?? 0) * relevanceCutoff

        var selected: [MeetingChunk] = []
        var used = 0
        var perMeeting: [PersistentIdentifier: Int] = [:]
        for (position, item) in ranked.enumerated() {
            // Always keep the top couple so there's something to answer from.
            if position >= 2 && item.score < threshold { break }
            let count = perMeeting[item.chunk.meetingID, default: 0]
            guard count < maxChunksPerMeeting else { continue }
            guard used + item.chunk.text.count <= characterBudget else { continue }
            selected.append(item.chunk)
            used += item.chunk.text.count
            perMeeting[item.chunk.meetingID] = count + 1
        }
        return selected
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "who", "whom", "why", "how",
        "did", "does", "do", "you", "your", "our", "with", "about", "that", "this", "these", "those",
        "have", "has", "had", "from", "into", "they", "them", "their", "there", "then", "than", "any",
        "all", "can", "could", "would", "should", "will", "said", "say", "tell", "meeting", "meetings",
        "last", "week", "today", "yesterday", "month", "past", "days", "which", "been", "being", "its",
    ]

    /// Meaningful words from the question, trimmed so "budgets" also finds "budget".
    static func keywords(in question: String) -> [String] {
        question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
            .map { $0.count > 5 ? String($0.prefix($0.count - 2)) : $0 }
    }

    private static func sentenceEmbedding(for text: String) -> NLEmbedding? {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        return NLEmbedding.sentenceEmbedding(for: language) ?? NLEmbedding.sentenceEmbedding(for: .english)
    }
}
