import SwiftUI
import SwiftData
import AppKit

struct RecorderView: View {
    @Bindable var session: RecordingSession

    private enum Pane: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case notes = "Notes"
        var id: Self { self }
    }

    /// Wide enough for transcript and notes side by side.
    private static let splitBreakpoint: CGFloat = 620
    private static let minTranscriptWidth: CGFloat = 320
    private static let minNotesWidth: CGFloat = 220
    private static let maxNotesWidth: CGFloat = 480
    /// Wide enough for full button titles in the header.
    private static let compactBreakpoint: CGFloat = 520

    @State private var width: CGFloat = 900
    @State private var showNotes = true
    @State private var narrowPane: Pane = .transcript
    @AppStorage("recorder.notesWidth") private var notesWidth: Double = 300
    @State private var dragStartWidth: CGFloat?

    /// Notes width kept inside limits so the transcript never gets squeezed out.
    private var clampedNotesWidth: CGFloat {
        let upper = max(Self.minNotesWidth, min(Self.maxNotesWidth, width - Self.minTranscriptWidth))
        return min(max(CGFloat(notesWidth), Self.minNotesWidth), upper)
    }

    private var isWide: Bool { width >= Self.splitBreakpoint }
    private var isCompact: Bool { width < Self.compactBreakpoint }
    private var headerControlSize: ControlSize { isCompact ? .regular : .large }

    var body: some View {
        // GeometryReader reports the space the window *offers*, not the size our
        // content ends up at. Measuring our own size fed back into the notes
        // width and locked the layout wider than the window, so it got cut off.
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                if let error = session.errorMessage {
                    errorBanner(error)
                }
                Divider()
                if isWide {
                    wideLayout
                } else {
                    narrowLayout
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onChange(of: proxy.size.width, initial: true) { _, newWidth in
                width = newWidth
            }
        }
    }

    // MARK: Layouts

    // Plain HStack rather than HSplitView: HSplitView won't shrink below its
    // panes' widths, which made the content overflow small windows.
    private var wideLayout: some View {
        HStack(spacing: 0) {
            transcript
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            if showNotes {
                resizeHandle
                notesPane
                    .frame(width: clampedNotesWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    /// Drag to resize the notes pane.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartWidth ?? clampedNotesWidth
                                if dragStartWidth == nil { dragStartWidth = start }
                                notesWidth = Double(start - value.translation.width)
                            }
                            .onEnded { _ in
                                notesWidth = Double(clampedNotesWidth)
                                dragStartWidth = nil
                            }
                    )
            }
    }

    private var narrowLayout: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $narrowPane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch narrowPane {
            case .transcript:
                transcript
            case .notes:
                notesPane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 8)
            // One group so the notes button and Record/Stop share a size, shape and centre line.
            HStack(spacing: 8) {
                if isWide {
                    Button {
                        withAnimation { showNotes.toggle() }
                    } label: {
                        Label(showNotes ? "Hide notes" : "Show notes", systemImage: "sidebar.right")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(showNotes ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.bordered)
                    .help(showNotes ? "Hide notes" : "Show notes")
                }
                controls
            }
            .controlSize(headerControlSize)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, isCompact ? 10 : 14)
    }

    /// Recording, paused, or switching between the two.
    private var isInMeeting: Bool {
        switch session.state {
        case .recording, .pausing, .paused, .resuming: return true
        default: return false
        }
    }

    @ViewBuilder
    private var status: some View {
        if isInMeeting, let start = session.startDate {
            HStack(spacing: isCompact ? 8 : 12) {
                if session.state == .recording {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse, options: .repeating)
                        .accessibilityLabel("Recording")
                } else {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Paused")
                }
                // The clock leaves out paused time, and stands still while paused.
                TimelineView(.periodic(from: start, by: 1)) { timeline in
                    Text(formatDuration(session.recordedTime(at: timeline.date)))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(session.state == .recording ? .primary : .secondary)
                }
                if session.state == .recording {
                    ListeningIndicator(levels: session.levels, compact: !isWide)
                        .padding(.leading, isCompact ? 0 : 4)
                } else if session.state == .paused && !isCompact {
                    Text("Paused")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Text("New meeting")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch session.state {
        case .idle:
            Button {
                Task { await session.start() }
            } label: {
                Label(isCompact ? "Record" : "Start recording", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Start recording (⇧⌘R here, \(RecordingSession.shortcutDisplay) from any app)")
        case .preparing:
            busy("Getting ready…")
        case .recording:
            Button {
                Task { await session.pause() }
            } label: {
                adaptiveLabel("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Pause recording (⇧⌘P). The microphone and Mac audio turn off until you resume.")
            stopButton
        case .pausing:
            busy("Pausing…")
        case .paused:
            Button {
                Task { await session.resume() }
            } label: {
                adaptiveLabel("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Resume recording (⇧⌘P)")
            stopButton
        case .resuming:
            busy("Resuming…")
        case .finishing:
            busy("Finishing transcript…")
        }
    }

    /// Icon only when the window is narrow, so Pause and Stop both fit.
    @ViewBuilder
    private func adaptiveLabel(_ title: String, systemImage: String) -> some View {
        if isCompact {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        } else {
            Label(title, systemImage: systemImage)
        }
    }

    private var stopButton: some View {
        Button {
            Task { await session.stop() }
        } label: {
            Label("Stop", systemImage: "stop.circle.fill")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Stop recording (⇧⌘R here, \(RecordingSession.shortcutDisplay) from any app)")
    }

    private func busy(_ message: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            if !isCompact {
                Text(message).foregroundStyle(.secondary)
            }
        }
        .help(message)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation { session.errorMessage = nil }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, isCompact ? 12 : 16)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.1))
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if session.segments.isEmpty && session.liveMe.isEmpty && session.liveOthers.isEmpty {
                        emptyState
                    }
                    ForEach(session.segments) { segment in
                        SegmentRow(speaker: segment.speaker, text: segment.text, offset: segment.offset)
                    }
                    if !session.liveOthers.isEmpty {
                        SegmentRow(speaker: .others, text: session.liveOthers, isLive: true)
                    }
                    if !session.liveMe.isEmpty {
                        SegmentRow(speaker: .me, text: session.liveMe, isLive: true)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(isCompact ? 12 : 16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.updateCounter) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if session.state == .recording {
                // A big moving waveform so it's obvious Noted is hearing you.
                HStack(spacing: isCompact ? 14 : 24) {
                    LiveWaveform(levels: session.levels, speaker: .me,
                                 bars: isCompact ? 10 : 16, barWidth: 4, spacing: 3, maxHeight: 44)
                    LiveWaveform(levels: session.levels, speaker: .others,
                                 bars: isCompact ? 10 : 16, barWidth: 4, spacing: 3, maxHeight: 44)
                }
                .padding(.bottom, 4)
            } else {
                Image(systemName: isInMeeting ? "pause.circle" : "mic.and.signal.meter")
                    .font(.system(size: isCompact ? 28 : 34))
                    .foregroundStyle(.secondary)
            }
            Text(session.state == .recording
                 ? "Listening… speak and you'll see the bars move."
                 : isInMeeting
                    ? "Paused. Nothing is being heard until you press Resume."
                    : "Press \(isCompact ? "Record" : "Start recording") when your meeting begins.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Noted listens to your microphone and your Mac's audio. No bot joins the call, and everything stays on this Mac. Use headphones so your mic doesn't pick up the other side twice.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isWide ? 60 : 24)
        .padding(.horizontal, 8)
    }

    // MARK: Notes

    private var notesPane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isWide {
                Text("Your notes")
                    .font(.headline)
            }
            Text("Jot down anything important. The summary will treat it as a priority.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $session.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(isCompact ? 12 : 16)
    }
}

/// One line of transcript, shared by the recorder and the meeting view.
struct SegmentRow: View {
    let speaker: Speaker
    let text: String
    var offset: TimeInterval? = nil
    var isLive = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(speaker.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speaker.tint)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(isLive ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let offset {
                    Text(formatDuration(offset))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        // Making every line selectable is slow with long transcripts, so a
        // single line is copied from its right-click menu instead.
        .contextMenu {
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(speaker.label): \(text)", forType: .string)
            }
        }
    }
}

