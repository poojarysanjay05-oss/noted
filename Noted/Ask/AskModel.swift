import Foundation
import SwiftData
import Observation
import FoundationModels

/// What the model returns: the answer, plus which numbered excerpts it used,
/// so only the meetings it actually drew on are shown as sources.
@Generable
struct MeetingAnswer {
    @Guide(description: "The answer, in plain sentences or a short list. Mention the meeting by its title where helpful. Do not include excerpt numbers or bracketed labels.")
    var answer: String

    @Guide(description: "The numbers of the excerpts this answer is based on, for example [2, 5]. Empty if the excerpts don't answer the question.")
    var sourceExcerpts: [Int]
}

/// Answers questions about your meetings with Apple's on-device model.
/// Keeps the conversation while Noted is open.
@MainActor
@Observable
final class AskModel {
    struct Source: Identifiable, Hashable {
        let id: PersistentIdentifier
        let title: String
        let date: Date
    }

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var note: String?
        var sources: [Source] = []
        var error: String?
        var isThinking = true
    }

    private(set) var exchanges: [Exchange] = []
    var draft = ""

    var isBusy: Bool { exchanges.last?.isThinking == true }

    func clear() {
        guard !isBusy else { return }
        exchanges = []
    }

    func ask(_ rawQuestion: String, meetings: [Meeting]) async {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isBusy else { return }
        draft = ""

        // The previous exchange, so follow-ups like "who owns that?" make sense.
        let previous = exchanges.last(where: { $0.answer != nil })
        exchanges.append(Exchange(question: question))
        let index = exchanges.count - 1

        do {
            if let reason = Summarizer.unavailableReason {
                throw NotedError(reason)
            }
            guard !meetings.isEmpty else {
                throw NotedError("You don't have any saved meetings yet. Record one, then ask away.")
            }

            // "last week", "yesterday" … narrow down which meetings to search.
            var pool = meetings
            if let filter = MeetingSearch.timeFilter(in: question) {
                let inRange = meetings.filter { filter.range.contains($0.date) }
                if inRange.isEmpty {
                    exchanges[index].note = "No meetings were recorded \(filter.phrase), so all meetings were searched."
                } else {
                    pool = inRange
                }
            }

            let chunks = MeetingSearch.chunks(for: pool)
            let excerpts = await Task.detached(priority: .userInitiated) {
                MeetingSearch.select(chunks, for: question)
            }.value
            guard !excerpts.isEmpty else {
                throw NotedError("Your meetings don't have any transcript or summary to search yet.")
            }

            let (answer, used) = try await generateAnswer(question: question, excerpts: excerpts, previous: previous)
            exchanges[index].answer = Self.cleaned(answer)
            exchanges[index].sources = Self.sources(from: used)
        } catch {
            exchanges[index].error = error.localizedDescription
        }
        exchanges[index].isThinking = false
    }

    // MARK: Talking to the model

    private static let instructions = """
        You answer questions about the user's own meetings, using only the meeting \
        excerpts provided. In transcripts, "You" is the user and "Others" are the \
        other participants. Each excerpt is numbered. Only use excerpts that are actually \
        about the question and ignore the rest. List the numbers of the excerpts you used. \
        If no excerpt answers the question, say you couldn't find it in the meetings and \
        list no excerpts. Never guess. Keep answers short: a few sentences or a brief list.
        """

    /// Returns the answer and the excerpts it says it used.
    private func generateAnswer(question: String, excerpts: [MeetingChunk], previous: Exchange?) async throws -> (String, [MeetingChunk]) {
        // Most relevant first. They're numbered in this order in the prompt, so the
        // model's numbers map straight back here.
        var excerpts = excerpts
        // If the model runs out of room, try once more with the more relevant half.
        for attempt in 0..<2 {
            let session = LanguageModelSession(instructions: Self.instructions)
            do {
                let prompt = Self.prompt(question: question, excerpts: excerpts, previous: previous)
                let result = try await session.respond(to: prompt, generating: MeetingAnswer.self).content
                let used = result.sourceExcerpts.compactMap { number in
                    excerpts.indices.contains(number - 1) ? excerpts[number - 1] : nil
                }
                return (result.answer, used)
            } catch {
                guard attempt == 0, excerpts.count > 2 else { throw error }
                excerpts = Array(excerpts.prefix(excerpts.count / 2))
            }
        }
        throw NotedError("Noted couldn't answer that. Try asking in a different way.")
    }

    private static func prompt(question: String, excerpts: [MeetingChunk], previous: Exchange?) -> String {
        var prompt = "Today is \(Date.now.formatted(date: .complete, time: .omitted)).\n\nMeeting excerpts:\n"
        for (index, excerpt) in excerpts.enumerated() {
            prompt += "\nExcerpt \(index + 1), from \(excerpt.label):\n\(excerpt.text)\n"
        }
        if let previous, let answer = previous.answer {
            prompt += "\nThe user's previous question was: \(previous.question)\n"
            prompt += "Your previous answer was: \(answer.prefix(600))\n"
        }
        prompt += "\nQuestion: \(question)"
        return prompt
    }

    /// Removes any bracketed label line the model copied from the excerpts,
    /// e.g. "[Budget review — 3 Oct 2026 at 5:57 PM]".
    private static func cleaned(_ answer: String) -> String {
        answer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !(trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The meetings the answer drew on, in the order cited, each listed once.
    private static func sources(from excerpts: [MeetingChunk]) -> [Source] {
        var seen = Set<PersistentIdentifier>()
        var result: [Source] = []
        for excerpt in excerpts where !seen.contains(excerpt.meetingID) {
            seen.insert(excerpt.meetingID)
            result.append(Source(id: excerpt.meetingID, title: excerpt.meetingTitle, date: excerpt.meetingDate))
        }
        return Array(result.prefix(5))
    }
}
