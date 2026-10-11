import SwiftUI
import SwiftData
import AppKit

/// Ask questions across all your meetings, answered on this Mac.
struct AskView: View {
    @Bindable var model: AskModel
    let meetings: [Meeting]
    var onOpenMeeting: (PersistentIdentifier) -> Void

    @FocusState private var inputFocused: Bool

    private let suggestions = [
        "What did we decide last week?",
        "What are my open action items?",
        "Summarize this week's meetings",
        "What did others ask me to follow up on?",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if model.exchanges.isEmpty {
                            intro
                        }
                        ForEach(model.exchanges) { exchange in
                            ExchangeView(exchange: exchange, onOpenMeeting: onOpenMeeting)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("end")
                    }
                    .padding(16)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.exchanges.count) {
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: model.isBusy) {
                    withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .toolbar {
            ToolbarItem {
                Button {
                    model.clear()
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .help("Start a new conversation")
                .disabled(model.exchanges.isEmpty || model.isBusy)
            }
        }
        .onAppear { inputFocused = true }
    }

    // MARK: Empty state

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
            Text("Ask your meetings")
                .font(.title2.weight(.semibold))
            Text("Ask about decisions, promises, dates or anything that was said. Noted finds the relevant parts of your meetings and Apple Intelligence answers on this Mac. Nothing leaves your computer.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if meetings.isEmpty {
                Label("Record a meeting first. Then you can ask about it here.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Try asking")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            send(suggestion)
                        } label: {
                            Label(suggestion, systemImage: "arrow.up.right")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.top, 24)
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about your meetings…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onSubmit { send(model.draft) }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            Button {
                send(model.draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Ask (Return)")
            .accessibilityLabel("Ask")
        }
        .padding(12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !model.isBusy && !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ text: String) {
        guard !model.isBusy else { return }
        Task { await model.ask(text, meetings: meetings) }
    }
}

/// One question and its answer.
private struct ExchangeView: View {
    let exchange: AskModel.Exchange
    var onOpenMeeting: (PersistentIdentifier) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The question, on the right like a chat message.
            HStack {
                Spacer(minLength: 40)
                Text(exchange.question)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if exchange.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking through your meetings…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = exchange.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let answer = exchange.answer {
                answerView(answer)
            }
        }
    }

    private func answerView(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(Self.rendered(answer))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            if let note = exchange.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !exchange.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(exchange.sources) { source in
                        Button {
                            onOpenMeeting(source.id)
                        } label: {
                            Label {
                                Text("\(source.title) · \(source.date.formatted(date: .abbreviated, time: .omitted))")
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "doc.text")
                            }
                            .font(.callout)
                        }
                        .buttonStyle(.link)
                        .help("Open this meeting")
                    }
                }
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
            } label: {
                Label("Copy answer", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
    }

    /// Shows **bold** and other inline Markdown the model uses, keeping line breaks.
    private static func rendered(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
