#if DEBUG
import Foundation
import SwiftData
import AppKit

/// Sample meetings for screenshots and trying the app out.
///
/// Only exists in Debug builds (running from Xcode). When it's on, Noted uses an
/// in-memory library filled with made-up meetings, so your real meetings are
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
        Sample(
            title: "Design Handoff: Onboarding Flow",
            daysAgo: 1, hour: 15, minutes: 27,
            overview: "Design walked engineering through the new three-step onboarding flow. The main open question was whether to ask for notification permission during onboarding or after the first meeting is recorded; the team chose to wait until after the first meeting. Engineering estimated two sprints.",
            keyPoints: [
                "Onboarding shrinks from five screens to three",
                "Permission prompts are explained before macOS shows them",
                "Engineering estimate is two sprints",
            ],
            decisions: [
                "Ask for notification permission after the first recorded meeting, not during onboarding",
                "Ship behind a feature flag for internal testing first",
            ],
            actionItems: [
                "Elena: export final assets and add them to the handoff file",
                "You: write the feature-flag plan",
                "Engineering: spike the permission explainer screen",
            ],
            notes: "",
            lines: [
                (.others, "So the new flow is three screens instead of five. Welcome, permissions, and a quick test recording."),
                (.me, "I like that the permissions screen explains why before macOS asks."),
                (.others, "That was the main goal. People were denying screen recording because the system prompt is scary on its own."),
                (.me, "What about notifications? Do we ask for those here too?"),
                (.others, "I'd rather wait until after their first meeting, when the reminder actually makes sense."),
                (.me, "Agreed, let's ask after the first recording. How long do we think this takes to build?"),
                (.others, "Roughly two sprints, including the explainer animations."),
                (.me, "Let's put it behind a feature flag and test it internally first. I'll write up the flag plan."),
            ]
        ),
        Sample(
            title: "Weekly Product Sync",
            daysAgo: 3, hour: 11, minutes: 31,
            overview: "A status round on the 2.4 mobile release. The checkout crash fix is verified, App Store review is pending, and the analytics dashboard slipped a week because of a data pipeline issue. The team agreed to ship 2.4 without the dashboard.",
            keyPoints: [
                "Checkout crash fix verified on all supported devices",
                "Build 2.4 is waiting for App Store review",
                "Analytics dashboard slipped a week due to a pipeline bug",
            ],
            decisions: [
                "Ship 2.4 without the analytics dashboard; it follows in 2.4.1",
            ],
            actionItems: [
                "You: update the release notes to drop the dashboard",
                "Sam: fix the pipeline bug and share a new date",
            ],
            notes: "Tell support the dashboard is coming in 2.4.1.",
            lines: [
                (.me, "Quick round today. Where are we with 2.4?"),
                (.others, "The checkout crash fix is verified on every device we support, and the build is in App Store review."),
                (.me, "Great. And the analytics dashboard?"),
                (.others, "It slipped about a week. There's a bug in the data pipeline that double counts sessions."),
                (.me, "Then let's not hold the release for it. We ship 2.4 now and the dashboard follows in 2.4.1."),
                (.others, "Makes sense. I'll fix the pipeline and come back with a new date."),
                (.me, "I'll update the release notes to drop the dashboard."),
            ]
        ),
        Sample(
            title: "Candidate Debrief: Senior iOS Engineer",
            daysAgo: 8, hour: 16, minutes: 22,
            overview: "The panel debriefed after interviewing a senior iOS engineer candidate. Strong SwiftUI and concurrency skills, good communication, and a thoughtful system design answer. Some concern about limited experience with audio frameworks. The panel recommended moving to an offer.",
            keyPoints: [
                "Strong SwiftUI, Swift concurrency and testing practices",
                "Clear communicator, asked good product questions",
                "Limited hands-on experience with AVFoundation and audio",
            ],
            decisions: [
                "Recommend moving forward with an offer",
            ],
            actionItems: [
                "You: send feedback summary to the recruiter today",
                "Recruiter: schedule the reference checks",
            ],
            notes: "Pair them with Marcus on audio work for the first month.",
            lines: [
                (.me, "Let's go round the panel. Overall impressions?"),
                (.others, "Very strong on SwiftUI and concurrency. The actor isolation discussion was excellent."),
                (.others, "System design was good too. They asked smart questions about offline sync before jumping in."),
                (.me, "Any concerns?"),
                (.others, "Not much audio experience. They've never worked with AVFoundation directly."),
                (.me, "That's learnable, and we can pair them with Marcus at the start. Are we all comfortable recommending an offer?"),
                (.others, "Yes, strong yes from me."),
                (.me, "Great, I'll send the summary to the recruiter today."),
            ]
        ),
    ]
}
#endif
