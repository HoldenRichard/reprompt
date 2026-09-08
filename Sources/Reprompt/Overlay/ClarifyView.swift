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

/// Small buttons that wrap onto further lines rather than compressing to fit one row.
struct FlowChips: View {
    let items: [String]
    var onPick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(item) { onPick(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A left-aligned layout that places subviews in rows, wrapping when the next one would
/// overflow the proposed width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
