#if DEBUG
import Foundation
import SwiftData
import AppKit

/// A sample meeting for screenshots and trying the app out.
///
/// Only exists in Debug builds (running from Xcode). When it's on, Noted uses an
/// in-memory library with one made-up meeting, so your real meetings are
/// never opened or changed. Toggle it from the Developer menu.
enum DemoMode {
    private static let defaultsKey = "NotedDemoMode"

    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Flips demo mode and relaunches Noted so the right library is opened.
    @MainActor
    static func toggleAndRelaunch() {
        UserDefaults.standard.set(!isOn, forKey: defaultsKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Sample data

    private struct Sample {
        let title: String
        let daysAgo: Int
        let hour: Int
        let minutes: Double
        let overview: String
        let keyPoints: [String]
        let decisions: [String]
        let actionItems: [String]
        let notes: String
        let lines: [(Speaker, String)]
    }

    @MainActor
    static func seed(into context: ModelContext) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)

        for sample in samples {
            let day = calendar.date(byAdding: .day, value: -sample.daysAgo, to: today) ?? today
            let date = calendar.date(bySettingHour: sample.hour, minute: 0, second: 0, of: day) ?? day
            let duration = sample.minutes * 60

            let meeting = Meeting(title: sample.title, date: date, duration: duration, notes: sample.notes)
            meeting.overview = sample.overview
            meeting.keyPoints = sample.keyPoints
            meeting.decisions = sample.decisions
            meeting.actionItems = sample.actionItems
            context.insert(meeting)

            let step = duration / Double(max(sample.lines.count, 1))
            for (index, line) in sample.lines.enumerated() {
                meeting.segments.append(
                    TranscriptSegment(speaker: line.0, text: line.1, offset: Double(index) * step + 4)
                )
            }
        }
        try? context.save()
    }

    private static let samples: [Sample] = [
        Sample(
            title: "Q4 Budget Review",
            daysAgo: 0, hour: 10, minutes: 38,
            overview: "The team reviewed Q4 spending against plan. Marketing is 12% over because of the conference push, while infrastructure came in under budget after the database migration. The group agreed to move part of the infrastructure savings to marketing and freeze new tool subscriptions until January.",
            keyPoints: [
                "Marketing is 12% over plan, mostly from the October conference",
                "Infrastructure is $18k under budget after the database migration",
                "Contractor spend is on track",
                "Two unused SaaS subscriptions were found during the review",
            ],
            decisions: [
                "Move $10k of infrastructure savings to the marketing budget",
                "Freeze new tool subscriptions until January",
                "Cancel the two unused SaaS subscriptions",
            ],
            actionItems: [
                "You: send the revised budget sheet to finance by Friday",
                "Priya: cancel the unused design and survey tool subscriptions",
                "Marcus: share the conference ROI report next week",
            ],
            notes: "Ask finance whether the $10k move needs CFO sign-off.\nConference ROI — Marcus to share numbers.",
            lines: [
                (.me, "Okay, let's start with the big picture. Where are we against plan for the quarter?"),
                (.others, "Overall we're about 3% over, but it's not evenly spread. Marketing is 12% over and infrastructure is well under."),
                (.me, "Marketing being over is mostly the October conference, right?"),
                (.others, "Yes, the booth and travel came in higher than we estimated. Leads were strong though, Marcus has the numbers."),
                (.others, "I can share a proper ROI breakdown next week once the pipeline data settles."),
                (.me, "Great. And infrastructure, how far under are we?"),
                (.others, "About eighteen thousand. The database migration cut our hosting bill more than expected."),
                (.me, "Then I'd suggest we move ten thousand of that to marketing and keep the rest as a buffer."),
                (.others, "That works for me. We also found two subscriptions nobody's using, the old survey tool and a design plugin."),
                (.me, "Let's cancel both. Priya, can you take that?"),
                (.others, "Sure, I'll cancel them this week."),
                (.me, "And no new tool subscriptions until January unless they're critical. I'll send the revised sheet to finance by Friday."),
            ]
        ),
    ]
}
#endif
