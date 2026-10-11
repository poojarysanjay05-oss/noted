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
    @State private var isSummarizing = false
    @State private var copied = false
    @State private var width: CGFloat = 900

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
                    Task { await summarize() }
                } label: {
                    Label("Regenerate summary", systemImage: "sparkles")
                }
                .help("Regenerate summary")
                .disabled(isSummarizing || meeting.segments.isEmpty)

                // Click copies whatever tab is showing; the arrow offers "Copy everything".
                Menu {
                    Button("Copy \(tab.copyName)") { copy(textForCurrentTab) }
                        .disabled(textForCurrentTab == nil)
                    Button("Copy everything (Markdown)") { copy(meeting.markdown) }
                } label: {
                    Label(copied ? "Copied" : "Copy \(tab.copyName)",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                } primaryAction: {
                    copy(textForCurrentTab)
                }
                .help(textForCurrentTab == nil
                      ? "Nothing to copy on this tab yet"
                      : "Copy the \(tab.copyName.lowercased())")
            }
        }
        .task(id: meeting.persistentModelID) {
            tab = .summary
            if meeting.overview == nil && meeting.summaryError == nil && !meeting.segments.isEmpty {
                await summarize()
            }
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
            if meeting.segments.isEmpty {
                Text("No speech was captured in this meeting.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(meeting.orderedSegments) { segment in
                        SegmentRow(speaker: segment.speaker, text: segment.text, offset: segment.offset)
                    }
                }
            }
        case .notes:
            EmptyView()
        }
    }

    @ViewBuilder
    private var summaryView: some View {
        if isSummarizing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing the summary on this Mac…")
            }
            .foregroundStyle(.secondary)
        } else if let error = meeting.summaryError {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Button("Try again") { Task { await summarize() } }
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
        } else if meeting.segments.isEmpty {
            Text("No speech was captured in this meeting, so there's nothing to summarize.")
                .foregroundStyle(.secondary)
        } else {
            Button("Generate summary") { Task { await summarize() } }
        }
    }

    private func summarize() async {
        isSummarizing = true
        await SummaryRunner.run(for: meeting)
        isSummarizing = false
    }

    /// The text the copy button copies for the tab that's showing.
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
