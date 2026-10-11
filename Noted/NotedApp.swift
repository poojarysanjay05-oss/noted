import SwiftUI
import SwiftData
import AppKit

@main
struct NotedApp: App {
    private let container: ModelContainer
    @State private var session: RecordingSession

    init() {
        #if DEBUG
        // Demo mode (Debug menu) uses made-up meetings kept only in memory.
        let isDemo = DemoMode.isOn
        #else
        let isDemo = false
        #endif

        let container: ModelContainer
        do {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: isDemo)
            container = try ModelContainer(
                for: Meeting.self, TranscriptSegment.self,
                configurations: configuration
            )
        } catch {
            fatalError("Noted couldn't open its meeting library: \(error)")
        }
        self.container = container

        #if DEBUG
        if isDemo {
            DemoMode.seed(into: container.mainContext)
        }
        #endif

        // One recording session shared by the window, the menu bar and the shortcut.
        let session = RecordingSession(context: container.mainContext)
        session.recoverInterruptedMeetings()
        session.installGlobalShortcut()
        _session = State(initialValue: session)
    }

    var body: some Scene {
        // A single window, so there is only ever one recording session.
        Window("Noted", id: "main") {
            ContentView()
                // Small enough to sit beside a video call; the layout adapts down to this.
                .frame(minWidth: 420, minHeight: 380)
                .environment(session)
        }
        .defaultSize(width: 1100, height: 720)
        // The window can never be dragged smaller than its content can fit.
        .windowResizability(.contentMinSize)
        .modelContainer(container)
        #if DEBUG
        .commands {
            CommandMenu("Developer") {
                Toggle("Demo Mode (sample meetings)", isOn: Binding(
                    get: { DemoMode.isOn },
                    set: { _ in DemoMode.toggleAndRelaunch() }
                ))
            }
        }
        #endif

        // Start and stop from the menu bar; the icon turns into a record dot while recording.
        MenuBarExtra {
            MenuBarContent()
                .environment(session)
        } label: {
            Image(systemName: session.state == .recording ? "record.circle.fill" : "waveform")
                .accessibilityLabel(session.state == .recording ? "Noted is recording" : "Noted")
        }
        .modelContainer(container)
    }
}

/// The menu that drops down from Noted's menu bar icon.
private struct MenuBarContent: View {
    @Environment(RecordingSession.self) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch session.state {
        case .idle:
            Button("Start Recording  \(RecordingSession.shortcutDisplay)") {
                Task { await session.start() }
            }
        case .preparing:
            Text("Getting ready…")
        case .recording:
            if let start = session.startDate {
                Text("Recording since \(start.formatted(date: .omitted, time: .shortened))")
            }
            Button("Stop Recording  \(RecordingSession.shortcutDisplay)") {
                Task { await session.stop() }
            }
        case .finishing:
            Text("Finishing transcript…")
        }

        if let error = session.errorMessage {
            Divider()
            Text(error)
        }

        Divider()
        Button("Open Noted") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Quit Noted") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
