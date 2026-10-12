import SwiftUI
import SwiftData
import AppKit

struct MeetingDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "My notes"
        var id: Self { self }

        /// Name used on the copy button, e.g. "Copy Summary".
        var copyName: String {
            switch self {
            case .summary: return "Summary"
            case .transcript: return "Transcript"
            case .notes: return "Notes"
            }
        }
    }

    @Bindable var meeting: Meeting
    @State private var tab: Tab = .summary
    /// Summaries run app-wide, so they carry on if you switch meetings.
    private var summaryProgress: SummaryCenter.Progress? {
        SummaryCenter.shared.progress(for: meeting)
    }
    private var isSummarizing: Bool { summaryProgress != nil }
    @State private var copied = false
    @State private var width: CGFloat = 900
    /// Loaded once per meeting (see .task) rather than on every redraw.
    @State private var transcript: [TranscriptLine] = []

    private var isCompact: Bool { width < 520 }
    private var edgePadding: CGFloat { isCompact ? 12 : 20 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if tab == .notes {
                TextEditor(text: $meeting.notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(edgePadding)
            } else {
                ScrollView {
                    content
                        .padding(edgePadding)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    summarize()
                } label: {
                    Label(meeting.overview == nil ? "Generate summary" : "Regenerate summary",
                          systemImage: "sparkles")
                }
                .help(meeting.overview == nil ? "Generate summary" : "Regenerate summary")
                .disabled(isSummarizing || transcript.isEmpty)

                // Click copies whatever tab is showing; the arrow offers "Copy everything".
                Menu {
                    Button("Copy \(tab.copyName)") { copy(textForCurrentTab) }
                        .disabled(!canCopyCurrentTab)
                    Button("Copy everything (Markdown)") { copy(meeting.markdown) }
                } label: {
                    Label(copied ? "Copied" : "Copy \(tab.copyName)",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                } primaryAction: {
                    copy(textForCurrentTab)
                }
                .help(canCopyCurrentTab
                      ? "Copy the \(tab.copyName.lowercased())"
                      : "Nothing to copy on this tab yet")
            }
        }
        // Summaries are only written when you ask (Generate summary): it's
        // heavy on-device work that can slow the whole Mac for long meetings.
        .task(id: meeting.persistentModelID) {
            tab = .summary
            transcript = meeting.transcriptLines
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wraps onto more lines instead of cutting off long titles.
            TextField("Title", text: $meeting.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(isCompact ? .title3.weight(.semibold) : .title2.weight(.semibold))
                .lineLimit(1...3)
            Text("\(meeting.date.formatted(date: isCompact ? .abbreviated : .complete, time: .shortened)) · \(formatDuration(meeting.duration))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .padding(.top, 6)
        }
        .padding(.horizontal, edgePadding)
        .padding(.vertical, isCompact ? 12 : 16)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:
            summaryView
        case .transcript:
            if transcript.isEmpty {
                Text("No speech was captured in this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(transcript) { line in
                        SegmentRow(speaker: line.speaker, text: line.text, offset: line.offset)
                    }
                }
            }
        case .notes:
            EmptyView()
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if let progress = summaryProgress {
            VStack(alignment: .leading, spacing: 10) {
                Text("Writing the summary on this Mac")
                    .font(.headline)
                ProgressView(value: Double(progress.step), total: Double(max(progress.total, 1))) {
                    Text(progress.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 420)
                Text("You can keep using Noted while this runs. Finished parts are saved, so cancelling doesn't lose work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Cancel") {
                    SummaryCenter.shared.cancel(meeting)
                }
                .padding(.top, 2)
            }
        } else if let error = meeting.summaryError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") { summarize() }
            }
        } else if let overview = meeting.overview {
            VStack(alignment: .leading, spacing: 22) {
                Text(overview)
                    .font(.body)
                    .lineSpacing(3)
                BulletSection(title: "Key points", items: meeting.keyPoints)
                BulletSection(title: "Decisions", items: meeting.decisions)
                BulletSection(title: "Action items", items: meeting.actionItems, checkboxes: true)
            }
            .textSelection(.enabled)
        } else if transcript.isEmpty {
            Text("No speech was captured in this meeting, so there's nothing to summarize.")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("No summary yet")
                    .font(.headline)
                Text("Apple Intelligence can write an overview, key points, decisions and action items for this meeting, here on your Mac. Long meetings can take a few minutes.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    summarize()
                } label: {
                    Label("Generate summary", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    private func summarize() {
        SummaryCenter.shared.start(meeting)
    }

    /// Cheap check used while drawing; the copy text itself is only built on click.
    private var canCopyCurrentTab: Bool {
        switch tab {
        case .summary: return meeting.overview != nil
        case .transcript: return !transcript.isEmpty
        case .notes: return meeting.hasNotes
        }
    }

    /// The text the copy button copies for the tab that's showing. Only call
    /// from a click: for long meetings this is a lot of text.
    private var textForCurrentTab: String? {
        switch tab {
        case .summary: return meeting.summaryMarkdown
        case .transcript: return meeting.transcriptCopyText
        case .notes: return meeting.notesCopyText
        }
    }

    private func copy(_ text: String?) {
        guard let text else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

private struct BulletSection: View {
    let title: String
    let items: [String]
    var checkboxes = false

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: checkboxes ? "square" : "circle.fill")
                            .font(checkboxes ? .body : .system(size: 5))
                            .foregroundStyle(.secondary)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
