import Foundation
import AVFoundation
import AppKit
import SwiftData
import Observation
import Carbon.HIToolbox

struct LiveSegment: Identifiable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    let offset: TimeInterval
}

/// Runs one recording: captures audio, transcribes it live, and saves the
/// meeting as it goes. Owned by the app so the window, the menu bar icon and the
/// global shortcut all control the same recording.
@MainActor
@Observable
final class RecordingSession {
    enum State: Equatable {
        case idle, preparing, recording, finishing
    }

    /// The system-wide shortcut, shown in menus: Control-Option-R.
    static let shortcutDisplay = "⌃⌥R"

    private(set) var state: State = .idle
    private(set) var segments: [LiveSegment] = []
    private(set) var liveMe = ""
    private(set) var liveOthers = ""
    /// Bumps on every transcript change so the view can auto-scroll.
    private(set) var updateCounter = 0
    private(set) var startDate: Date?
    /// Set when a recording is saved, so the window can open that meeting.
    private(set) var lastSavedMeetingID: PersistentIdentifier?
    var notes = ""
    var errorMessage: String?

    /// Live loudness of each stream, for the waveform. Read by the view directly.
    let levels = AudioLevels()

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var meeting: Meeting?
    @ObservationIgnored private var capture: AudioCapture?
    @ObservationIgnored private var micTranscriber: LiveTranscriber?
    @ObservationIgnored private var systemTranscriber: LiveTranscriber?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// In-progress words waiting to be shown; batched so the screen isn't
    /// redrawn for every tiny change the speech recognizer reports.
    @ObservationIgnored private var pendingLive: [Speaker: String] = [:]
    @ObservationIgnored private var liveFlushScheduled = false
    /// Condenses finished stretches of the meeting while recording, so the
    /// summary is mostly done by the time you stop.
    @ObservationIgnored private var condenseTask: Task<Void, Never>?
    private static let liveUpdateInterval: Duration = .milliseconds(150)

    /// How often notes, duration and new transcript lines are written to disk.
    private static let autosaveInterval: Duration = .seconds(5)

    init(context: ModelContext) {
        self.context = context
    }

    private var elapsed: TimeInterval {
        guard let startDate else { return 0 }
        return Date().timeIntervalSince(startDate)
    }

    // MARK: Start / stop

    func toggle() async {
        switch state {
        case .idle: await start()
        case .recording: await stop()
        case .preparing, .finishing: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        state = .preparing
        errorMessage = nil
        segments = []
        liveMe = ""
        liveOthers = ""
        notes = ""
        levels.reset()

        do {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw NotedError("Noted needs microphone access. Turn it on in System Settings → Privacy & Security → Microphone.")
            }

            let locale = await LiveTranscriber.preferredLocale()
            let handler: @MainActor (Speaker, String, Bool) -> Void = { [weak self] speaker, text, isFinal in
                self?.handle(speaker: speaker, text: text, isFinal: isFinal)
            }

            let mic = LiveTranscriber(speaker: .me)
            mic.onUpdate = handler
            micTranscriber = mic
            try await mic.start(locale: locale)

            let system = LiveTranscriber(speaker: .others)
            system.onUpdate = handler
            systemTranscriber = system
            try await system.start(locale: locale)

            let capture = AudioCapture()
            let levels = self.levels
            capture.onMicrophone = { [weak mic] buffer in
                levels.record(buffer.normalizedLevel, for: .me)
                mic?.append(buffer)
            }
            capture.onSystemAudio = { [weak system] buffer in
                levels.record(buffer.normalizedLevel, for: .others)
                system?.append(buffer)
            }
            capture.onError = { [weak self] error in
                Task { @MainActor in
                    self?.errorMessage = "Audio capture stopped: \(error.localizedDescription)"
                }
            }
            self.capture = capture
            try await capture.start()

            // Create the meeting on disk straight away so nothing is lost if
            // Noted quits or the Mac restarts mid-meeting.
            let start = Date()
            let meeting = Meeting(title: Meeting.defaultTitle(for: start), date: start, duration: 0, notes: "")
            meeting.isInProgress = true
            context.insert(meeting)
            try? context.save()
            self.meeting = meeting

            startDate = start
            state = .recording
            startAutosave()
            NSSound(named: NSSound.Name("Tink"))?.play()
        } catch {
            errorMessage = error.localizedDescription
            await capture?.stop()
            micTranscriber?.cancel()
            systemTranscriber?.cancel()
            capture = nil
            micTranscriber = nil
            systemTranscriber = nil
            state = .idle
        }
    }

    /// Stops recording and finishes saving the meeting.
    func stop() async {
        guard state == .recording else { return }
        state = .finishing
        autosaveTask?.cancel()
        autosaveTask = nil
        // Don't hold up stopping; the rest is condensed when you ask for the summary.
        condenseTask?.cancel()
        condenseTask = nil
        let duration = elapsed

        await capture?.stop()
        await micTranscriber?.finish()
        await systemTranscriber?.finish()

        // Keep any words that were still "in progress" when we stopped.
        flushPendingLive()
        for (speaker, text) in [(Speaker.me, liveMe), (Speaker.others, liveOthers)] where !text.isEmpty {
            addFinalSegment(LiveSegment(speaker: speaker, text: text, offset: duration))
        }
        liveMe = ""
        liveOthers = ""

        if let meeting {
            meeting.duration = duration
            meeting.notes = notes
            meeting.isInProgress = false
            try? context.save()
            lastSavedMeetingID = meeting.persistentModelID
        }
        NSSound(named: NSSound.Name("Pop"))?.play()

        meeting = nil
        capture = nil
        micTranscriber = nil
        systemTranscriber = nil
        segments = []
        notes = ""
        startDate = nil
        state = .idle
    }

    // MARK: Saving as we go

    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autosaveInterval)
                guard !Task.isCancelled else { return }
                self?.saveProgress()
            }
        }
    }

    private func saveProgress() {
        guard state == .recording, let meeting else { return }
        meeting.duration = elapsed
        meeting.notes = notes
        try? context.save()
    }

    /// Finishes any meetings left "in progress" by a crash, quit or restart.
    /// Called once at launch, before anything can be recording.
    func recoverInterruptedMeetings() {
        let descriptor = FetchDescriptor<Meeting>(predicate: #Predicate { $0.isInProgress == true })
        guard let interrupted = try? context.fetch(descriptor), !interrupted.isEmpty else { return }
        for meeting in interrupted {
            if meeting.segments.isEmpty && meeting.notes.isEmpty {
                context.delete(meeting) // nothing was captured
            } else {
                meeting.isInProgress = false
                let lastLine = meeting.segments.map(\.offset).max() ?? 0
                meeting.duration = max(meeting.duration, lastLine)
            }
        }
        try? context.save()
    }

    // MARK: Transcript updates

    private func handle(speaker: Speaker, text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            pendingLive[speaker] = nil
            if !trimmed.isEmpty {
                addFinalSegment(LiveSegment(speaker: speaker, text: trimmed, offset: elapsed))
            }
            setLive("", for: speaker)
            updateCounter += 1
        } else {
            pendingLive[speaker] = trimmed
            guard !liveFlushScheduled else { return }
            liveFlushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.liveUpdateInterval)
                self?.flushPendingLive()
            }
        }
    }

    private func flushPendingLive() {
        liveFlushScheduled = false
        guard !pendingLive.isEmpty else { return }
        for (speaker, text) in pendingLive {
            setLive(text, for: speaker)
        }
        pendingLive = [:]
        updateCounter += 1
    }

    /// Shows a settled line and adds it to the saved meeting (written to disk by autosave).
    private func addFinalSegment(_ segment: LiveSegment) {
        segments.append(segment)
        meeting?.segments.append(
            TranscriptSegment(speaker: segment.speaker, text: segment.text, offset: segment.offset)
        )
        if state == .recording {
            condenseInBackgroundIfReady()
        }
    }

    /// Once about ten minutes of new transcript has built up, condenses it into
    /// short notes in the background. The latest, unfinished stretch is left for
    /// when you ask for the summary.
    private func condenseInBackgroundIfReady() {
        guard state == .recording, condenseTask == nil, let meeting,
              Summarizer.unavailableReason == nil else { return }
        // Live lines are in time order, the same order the saved meeting uses.
        let lines = segments.map { SummaryLine(speaker: $0.speaker.label, text: $0.text) }
        let start = meeting.condensedSegmentCount
        guard let chunk = Summarizer.chunk(lines, from: start, requireFull: true) else { return }

        let target = meeting
        condenseTask = Task(priority: .background) { [weak self] in
            let note = try? await Summarizer.condense(chunk.text)
            // Stopped (or a new recording started) while this was running: drop it.
            guard let self, self.meeting === target else { return }
            if let note, !Task.isCancelled, target.condensedSegmentCount == start {
                if !note.isEmpty { target.condensedNotes.append(note) }
                target.condensedSegmentCount = chunk.end
            }
            self.condenseTask = nil
            self.condenseInBackgroundIfReady()   // catch up if more is already waiting
        }
    }

    private func setLive(_ text: String, for speaker: Speaker) {
        switch speaker {
        case .me: liveMe = text
        case .others: liveOthers = text
        }
    }

    // MARK: Global shortcut

    /// Registers Control-Option-R to start or stop recording from any app.
    func installGlobalShortcut() {
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(controlKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in
                await self?.toggle()
            }
        }
    }
}
