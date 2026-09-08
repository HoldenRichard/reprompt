import RepromptCore
import SwiftUI

struct ClarifyView: View {
    let questions: ClarifyQuestions
    @Binding var answers: [String]
    var onSubmit: () -> Void
    @FocusState private var focused: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(questions.questions.enumerated()), id: \.element.id) { index, q in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q.question).font(.callout.weight(.medium))
                        if !q.why.isEmpty {
                            Text(q.why).font(.caption).foregroundStyle(.secondary)
                        }
                        if index < answers.count {
                            TextField("Your answer (optional)", text: $answers[index])
                                .textFieldStyle(.roundedBorder)
                                .focused($focused, equals: index)
                                .onSubmit { advance(from: index) }
                        }
                        if !q.suggestedAnswers.isEmpty {
                            FlowChips(items: q.suggestedAnswers) { pick in
                                if index < answers.count { answers[index] = pick }
                            }
                        }
                    }
                }
                Text("Skipped questions are left to the model's judgment. ⌘↩ to continue.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
        }
        .onAppear { focused = 0 }
    }

    private func advance(from index: Int) {
        if index + 1 < questions.questions.count { focused = index + 1 } else { onSubmit() }
    }
}

/// Simple wrapping row of small buttons.
struct FlowChips: View {
    let items: [String]
    var onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(item) { onPick(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
