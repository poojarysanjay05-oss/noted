import Foundation
import FoundationModels
import SwiftData
import Observation

/// The structured summary Apple Intelligence fills in.
@Generable
struct MeetingSummary {
    @Guide(description: "A short, specific title for the meeting, at most 8 words")
    var title: String

    @Guide(description: "A 2 to 4 sentence overview of what the meeting covered")
    var overview: String

    @Guide(description: "The most important points discussed, one short sentence each. Include every important point; don't leave any out")
    var keyPoints: [String]

    @Guide(description: "Every decision that was made. Empty if none were made")
    var decisions: [String]

    @Guide(description: "Every follow-up task, naming the owner when one was mentioned. Empty if there are none")
    var actionItems: [String]
}

/// One transcript line as plain values, safe to hand to background work.
struct SummaryLine: Sendable {
    let speaker: String
    let text: String
}

/// Summarizes meetings with Apple's on-device language model (macOS 26).
/// Nothing leaves the Mac.
///
/// The model reads about 4,000 tokens at a time (prompt and answer together),
/// so long meetings are summarized in two stages:
///  1. **Condense**: each ~10-minute stretch of transcript becomes bullet
///     notes. These are saved on the meeting as they're made, and are
///     made in the background while recording, so most of this work is done
///     by the time you ask for a summary.
///  2. **Write**: the notes (or, for short meetings, the transcript itself)
///     become the overview, key points, decisions and action items.
enum Summarizer {
    /// Cleaned transcript text per condensing call (~2,000 tokens), leaving
    /// room in the model's window for the instructions and the notes it writes.
    static let chunkLimit = 8_000
    /// Material up to this size goes straight into the final write-up.
    static let directLimit = 7_000
    /// The user's own notes included in the final write-up, at most.
    static let notesLimit = 3_000
    /// Bumped when condensing changes, so notes made the old way are redone.
    static let condenseVersion = 2

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in System Settings to generate summaries."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready. Try again in a few minutes."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, so summaries aren't available."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
    }

    // MARK: Cleaning

    /// Lines made only of these words carry no meaning for a summary.
    /// ("yes" and "no" are kept: they can be answers to real questions.)
    private static let fillerWords: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "erm", "hmm", "hm", "mm", "mmm", "mhm", "uh-huh",
        "yeah", "yep", "yup", "okay", "ok", "sure", "cool", "great", "nice", "alright",
        "right", "so", "well", "like", "thanks", "thank", "you", "got", "it", "oh", "ah",
    ]

    /// A transcript line with hesitations removed, or nil if nothing is left.
    private static func clean(_ text: String) -> String? {
        let stripped = text
            .replacingOccurrences(of: #"(?i)\b(u+m+|u+h+|uhm|erm|h+m+|m+h+m+)\b[,.]?\s*"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = stripped.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        guard !words.isEmpty, !words.allSatisfy({ fillerWords.contains(String($0)) }) else { return nil }
        return String(stripped.prefix(chunkLimit))
    }

    /// The next stretch of transcript to condense, starting at line `start`.
    ///
    /// Filler is removed and consecutive lines by the same speaker are joined,
    /// which makes the text both shorter and easier for the model to follow.
    /// With `requireFull`, returns nil until a whole chunk's worth is waiting
    /// (used while recording, so the last stretch is left for later).
    static func chunk(_ lines: [SummaryLine], from start: Int, requireFull: Bool) -> (end: Int, text: String)? {
        guard start < lines.count else { return nil }
        var text = ""
        var lastSpeaker: String?
        var index = start
        while index < lines.count {
            let line = lines[index]
            if let cleaned = clean(line.text) {
                let piece = line.speaker == lastSpeaker ? " " + cleaned : "\n\(line.speaker): \(cleaned)"
                if !text.isEmpty && text.count + piece.count > chunkLimit {
                    return (index, text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                text += piece
                lastSpeaker = line.speaker
            }
            index += 1
        }
        if requireFull { return nil }
        return (lines.count, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Model calls

    /// Turns one stretch of transcript into bullet notes, keeping the detail.
    static func condense(_ text: String) async throws -> String {
        guard !text.isEmpty else { return "" }
        let session = LanguageModelSession(instructions: """
            You condense part of a meeting transcript into brief bullet notes. \
            "You" is the person using this app and "Others" are the other participants. \
            Keep who said what (You / Others), names, numbers, dates, decisions and \
            commitments. Skip small talk.
            """)
        let response = try await session.respond(to: "Transcript excerpt:\n\(text)")
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shortens a long list of notes until it fits in one final write-up.
    static func reduce(_ notes: [String]) async throws -> String {
        var material = notes.filter { !$0.isEmpty }.joined(separator: "\n")
        var rounds = 0
        while material.count > directLimit && rounds < 3 {
            var groups: [String] = []
            var current = ""
            for line in material.split(separator: "\n") {
                if !current.isEmpty && current.count + line.count + 1 > chunkLimit {
                    groups.append(current)
                    current = ""
                }
                current += String(line) + "\n"
            }
            if !current.isEmpty { groups.append(current) }
            var condensed: [String] = []
            for group in groups {
                try Task.checkCancellation()
                condensed.append(try await condense(group))
            }
            material = condensed.joined(separator: "\n")
            rounds += 1
        }
        return String(material.prefix(directLimit))
    }

    /// Writes the final structured summary from notes or a short transcript.
    static func write(material: String, notes: String) async throws -> MeetingSummary {
        let session = LanguageModelSession(instructions: """
            You write clear, factual meeting minutes. "You" is the person using this app \
            and "Others" are the other participants. Use only information from the \
            material. Do not invent names, dates or numbers.
            """)
        var prompt = "Meeting material:\n\(material)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            prompt += "\n\nThe user's own notes from the meeting (treat these as the most important points):\n\(trimmedNotes.prefix(notesLimit))"
        }
        let response = try await session.respond(to: prompt, generating: MeetingSummary.self)
        return response.content
    }
}

/// Runs summaries for any meeting, app-wide.
///
/// Work keeps going if you switch to another meeting, shows its progress, can
/// be cancelled, and only one summary runs per meeting at a time.
@MainActor
@Observable
final class SummaryCenter {
    static let shared = SummaryCenter()

    struct Progress: Equatable {
        var step: Int
        var total: Int
        var message: String
    }

    private(set) var progress: [PersistentIdentifier: Progress] = [:]
    @ObservationIgnored private var tasks: [PersistentIdentifier: Task<Void, Never>] = [:]

    func progress(for meeting: Meeting) -> Progress? {
        progress[meeting.persistentModelID]
    }

    func start(_ meeting: Meeting) {
        let id = meeting.persistentModelID
        guard tasks[id] == nil else { return }
        meeting.summaryError = nil
        progress[id] = Progress(step: 0, total: 1, message: "Getting ready…")
        tasks[id] = Task { [weak self] in
            await self?.run(meeting, id: id)
            self?.tasks[id] = nil
            self?.progress[id] = nil
        }
    }

    func cancel(_ meeting: Meeting) {
        tasks[meeting.persistentModelID]?.cancel()
    }

    private func run(_ meeting: Meeting, id: PersistentIdentifier) async {
        do {
            if let reason = Summarizer.unavailableReason { throw NotedError(reason) }

            let lines = meeting.summaryLines
            if meeting.condensedSegmentCount > lines.count
                || (!meeting.condensedNotes.isEmpty && meeting.condensedVersion != Summarizer.condenseVersion) {
                meeting.condensedNotes = []
                meeting.condensedSegmentCount = 0
            }

            let material: String
            let whole = Summarizer.chunk(lines, from: 0, requireFull: false)
            if meeting.condensedNotes.isEmpty, let whole, whole.end == lines.count,
               whole.text.count <= Summarizer.directLimit {
                // Short meeting: one pass straight from the transcript.
                material = whole.text
            } else {
                // Long meeting: condense whatever wasn't condensed during recording.
                var remaining = 0
                var probe = meeting.condensedSegmentCount
                while let next = Summarizer.chunk(lines, from: probe, requireFull: false) {
                    remaining += 1
                    probe = next.end
                }
                let total = remaining + 2
                var step = 0
                while meeting.condensedSegmentCount < lines.count {
                    try Task.checkCancellation()
                    let start = meeting.condensedSegmentCount
                    guard let next = Summarizer.chunk(lines, from: start, requireFull: false) else { break }
                    step += 1
                    progress[id] = Progress(step: step, total: total,
                                            message: "Reading part \(step) of \(max(remaining, step))…")
                    let note = try await Summarizer.condense(next.text)
                    guard !meeting.isDeleted else { return }
                    // Something else (like recording) may have condensed this part already.
                    if meeting.condensedSegmentCount == start {
                        if !note.isEmpty { meeting.condensedNotes.append(note) }
                        meeting.condensedSegmentCount = next.end
                        meeting.condensedVersion = Summarizer.condenseVersion
                        try? meeting.modelContext?.save()   // keep progress if Noted quits
                    }
                }
                try Task.checkCancellation()
                progress[id] = Progress(step: total - 1, total: total, message: "Pulling it together…")
                material = try await Summarizer.reduce(meeting.condensedNotes)
            }

            try Task.checkCancellation()
            if let current = progress[id] {
                progress[id] = Progress(step: max(current.total - 1, 0), total: current.total,
                                        message: "Writing the summary…")
            }
            let summary = try await Summarizer.write(material: material, notes: meeting.notes)
            guard !meeting.isDeleted else { return }
            meeting.overview = summary.overview
            meeting.keyPoints = summary.keyPoints
            meeting.decisions = summary.decisions
            meeting.actionItems = summary.actionItems
            if meeting.title.hasPrefix(Meeting.defaultTitlePrefix) && !summary.title.isEmpty {
                meeting.title = summary.title
            }
            try? meeting.modelContext?.save()
        } catch is CancellationError {
            // Cancelled: parts already condensed stay saved, so the next try is quicker.
        } catch {
            // Cancelling can surface as the model's own error; that isn't a failure.
            guard !Task.isCancelled, !meeting.isDeleted else { return }
            meeting.summaryError = error.localizedDescription
        }
    }
}
