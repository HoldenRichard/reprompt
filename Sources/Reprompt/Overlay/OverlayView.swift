import RepromptCore
import SwiftUI

struct OverlayView: View {
    @Bindable var session: RepromptSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 520, height: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .padding(1)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: session.mode.symbol).foregroundStyle(.secondary)
            Text(session.mode.title).font(.headline)
            Text(ModelCatalog.infoOrGeneric(for: session.servedModel).displayName)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            statusText.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var statusText: Text {
        switch session.phase {
        case .grabbing: Text("Reading selection…")
        case .askingQuestions: Text("Thinking of questions…")
        case .questions: Text("Answer, then ⌘↩")
        case .streaming: Text(session.ttfbMs.map { String(format: "first token %.0f ms", $0) } ?? "Waiting…")
        case .result, .editing: Text(session.totalMs.map { String(format: "%.1f s", $0 / 1000) } ?? "")
        case .accepting: Text("Pasting…")
        case .failed: Text("Failed")
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .grabbing, .askingQuestions:
            VStack(spacing: 10) {
                ProgressView()
                Text(session.phase == .grabbing ? "Reading the selected text" : "Generating clarifying questions")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .questions:
            if let q = session.questions {
                ClarifyView(questions: q, answers: $session.answers, onSubmit: session.submitAnswers)
            }
        case .streaming, .result, .accepting:
            ScrollViewReader { proxy in
                ScrollView {
                    Text(session.text.isEmpty ? " " : session.text)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: session.text) { _, _ in
                    if session.phase == .streaming { proxy.scrollTo("end") }
                }
            }
        case .editing:
            TextEditor(text: $session.editText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(10)
        case .failed(let message, let missingKey):
            VStack(alignment: .leading, spacing: 12) {
                Label("Something went wrong", systemImage: "exclamationmark.triangle").font(.headline)
                Text(message).font(.callout).textSelection(.enabled)
                if missingKey {
                    Button("Open Settings") {
                        session.dismiss()
                        NSApp.activate()
                        openSettings()
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let n = session.notice {
                Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Dismiss") { session.dismiss() }
                .keyboardShortcut(.cancelAction)
            // The Questions step advertises Cmd+Return, so it needs a control that binds it.
            if session.canSubmitAnswers {
                Button("Continue") { session.submitAnswers() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            if session.phase == .result {
                Button("Edit") { session.beginEdit() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            if session.canAccept {
                Button("Copy") { session.copyResult() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Accept") { session.accept() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
