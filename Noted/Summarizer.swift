import Foundation
import FoundationModels

/// The structured summary Apple Intelligence fills in.
@Generable
struct MeetingSummary {
    @Guide(description: "A short, specific title for the meeting, at most 8 words")
    var title: String

    @Guide(description: "A 2 to 4 sentence overview of what the meeting covered")
    var overview: String

    @Guide(description: "The most important points discussed, one short sentence each")
    var keyPoints: [String]

    @Guide(description: "Decisions that were made. Empty if none were made")
    var decisions: [String]

    @Guide(description: "Follow-up tasks, naming the owner when one was mentioned. Empty if there are none")
    var actionItems: [String]
}

/// Summarizes meetings with Apple's on-device language model (macOS 26).
/// Nothing leaves the Mac.
enum Summarizer {
    /// The on-device model has a small context window, so long transcripts are
    /// condensed in chunks first, then summarized.
    private static let chunkLimit = 6_000
    private static let directLimit = 8_000

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

    static func summarize(transcript: String, notes: String) async throws -> MeetingSummary {
        if let reason = unavailableReason {
            throw NotedError(reason)
        }

        var material = transcript
        var rounds = 0
        while material.count > directLimit && rounds < 3 {
            material = try await condense(material)
            rounds += 1
        }

        let session = LanguageModelSession(instructions: """
            You write clear, factual meeting minutes. In the transcript, lines starting \
            "You:" were said by the person using this app and lines starting "Others:" \
            were said by other participants. Use only information from the material. \
            Do not invent names, dates or numbers.
            """)

        var prompt = "Meeting material:\n\(material)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            prompt += "\n\nThe user's own notes from the meeting (treat these as the most important points):\n\(trimmedNotes)"
        }

        let response = try await session.respond(to: prompt, generating: MeetingSummary.self)
        return response.content
    }

    /// Condenses each chunk of a long transcript into short notes.
    private static func condense(_ text: String) async throws -> String {
        var partials: [String] = []
        for chunk in chunks(of: text, limit: chunkLimit) {
            let session = LanguageModelSession(instructions: """
                You condense part of a meeting transcript into brief bullet notes. \
                Keep who said what (You / Others), names, numbers, decisions and commitments.
                """)
            let response = try await session.respond(to: "Transcript excerpt:\n\(chunk)")
            partials.append(response.content)
        }
        return partials.joined(separator: "\n")
    }

    private static func chunks(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit && !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += String(line) + "\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

@MainActor
enum SummaryRunner {
    static func run(for meeting: Meeting) async {
        meeting.summaryError = nil
        do {
            let summary = try await Summarizer.summarize(transcript: meeting.transcriptText, notes: meeting.notes)
            meeting.overview = summary.overview
            meeting.keyPoints = summary.keyPoints
            meeting.decisions = summary.decisions
            meeting.actionItems = summary.actionItems
            if meeting.title.hasPrefix(Meeting.defaultTitlePrefix) && !summary.title.isEmpty {
                meeting.title = summary.title
            }
        } catch {
            meeting.summaryError = error.localizedDescription
        }
    }
}
