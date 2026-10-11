import SwiftUI
import SwiftData

struct ContentView: View {
    enum Selection: Hashable {
        case recorder
        case ask
        case meeting(PersistentIdentifier)
    }

    @Environment(\.modelContext) private var context
    @Environment(RecordingSession.self) private var session
    // The meeting being recorded right now is saved as it goes, but it only
    // shows up in the list once it's finished.
    @Query(filter: #Predicate<Meeting> { $0.isInProgress == false },
           sort: \Meeting.date, order: .reverse)
    private var meetings: [Meeting]
    @State private var selection: Selection? = .recorder
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var searchText = ""
    /// Kept here so the conversation survives switching to a meeting and back.
    @State private var askModel = AskModel()

    /// Below this window width the sidebar tucks away (the toolbar button still shows it).
    private let sidebarBreakpoint: CGFloat = 680

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private struct SearchResult: Identifiable {
        let meeting: Meeting
        let snippet: String?
        var id: PersistentIdentifier { meeting.persistentModelID }
    }

    /// Meetings matching the search, each with a snippet showing where it matched.
    private var results: [SearchResult] {
        guard isSearching else { return meetings.map { SearchResult(meeting: $0, snippet: nil) } }
        return meetings.compactMap { meeting in
            guard let snippet = meeting.searchSnippet(for: searchText) else { return nil }
            return SearchResult(meeting: meeting, snippet: snippet.isEmpty ? nil : snippet)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings")
        } detail: {
            detail
        }
        // Only fires when the window crosses the breakpoint, so showing or hiding
        // the sidebar by hand is respected in between.
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width < sidebarBreakpoint
        } action: { isNarrow in
            withAnimation {
                columnVisibility = isNarrow ? .detailOnly : .all
            }
        }
        // Open each meeting as soon as it's saved, whether recording was stopped
        // here, from the menu bar or with the shortcut.
        .onChange(of: session.lastSavedMeetingID) { _, id in
            if let id {
                selection = .meeting(id)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            recorderRow
                .tag(Selection.recorder)
            Label("Ask your meetings", systemImage: "sparkles")
                .padding(.vertical, 2)
                .tag(Selection.ask)

            let results = self.results
            if isSearching {
                Section("Results") {
                    if results.isEmpty {
                        Text("No meetings match “\(searchText)”")
                            .foregroundStyle(.secondary)
                    }
                    rows(results)
                }
            } else if !results.isEmpty {
                Section("Meetings") {
                    rows(results)
                }
            }
        }
    }

    private func rows(_ results: [SearchResult]) -> some View {
        ForEach(results) { result in
            MeetingRow(meeting: result.meeting, snippet: result.snippet)
                .tag(Selection.meeting(result.meeting.persistentModelID))
                .contextMenu {
                    Button("Delete", role: .destructive) { delete(result.meeting) }
                }
        }
    }

    private var recorderRow: some View {
        Group {
            if session.state == .recording {
                Label("Recording…", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Label("New meeting", systemImage: "plus.circle")
            }
        }
        .font(.headline)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .meeting(let id):
            if let meeting = meetings.first(where: { $0.persistentModelID == id }) {
                MeetingDetailView(meeting: meeting)
            } else {
                ContentUnavailableView("Select a meeting", systemImage: "doc.text")
            }
        case .ask:
            AskView(model: askModel, meetings: meetings) { id in
                selection = .meeting(id)
            }
        case .recorder, .none:
            RecorderView(session: session)
        }
    }

    private func delete(_ meeting: Meeting) {
        if selection == .meeting(meeting.persistentModelID) {
            selection = .recorder
        }
        context.delete(meeting)
        try? context.save()
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    var snippet: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .lineLimit(1)
            Text("\(meeting.date.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(meeting.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
