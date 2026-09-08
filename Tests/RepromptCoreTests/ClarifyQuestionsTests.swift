import Foundation
import Testing
@testable import RepromptCore

/// Walks a JSON Schema and asserts the invariants the API enforces, so a malformed schema
/// is caught here rather than as a 400 on a user's first Clarify run.
func assertValidStrictSchema(_ value: JSONValue, path: String = "root", sourceLocation: SourceLocation = #_sourceLocation) {
    guard case .object(let o) = value else { return }
    if case .string("object")? = o["type"] {
        #expect(o["additionalProperties"] == .bool(false),
                "\(path): a strict object schema must set additionalProperties:false", sourceLocation: sourceLocation)
        guard case .object(let props)? = o["properties"] else {
            Issue.record("\(path): object schema has no properties", sourceLocation: sourceLocation); return
        }
        guard case .array(let required)? = o["required"] else {
            Issue.record("\(path): object schema has no required list", sourceLocation: sourceLocation); return
        }
        let requiredNames = required.compactMap { if case .string(let s) = $0 { s } else { nil } }
        #expect(Set(requiredNames) == Set(props.keys),
                "\(path): required \(requiredNames.sorted()) must match properties \(props.keys.sorted())",
                sourceLocation: sourceLocation)
        for (k, v) in props { assertValidStrictSchema(v, path: "\(path).\(k)", sourceLocation: sourceLocation) }
    }
    if case .string("array")? = o["type"] {
        guard let items = o["items"] else {
            Issue.record("\(path): array schema has no items", sourceLocation: sourceLocation); return
        }
        assertValidStrictSchema(items, path: "\(path)[]", sourceLocation: sourceLocation)
    }
}

@Suite struct ClarifyQuestionsTests {
    @Test func schemaIsAValidStrictObjectSchema() {
        assertValidStrictSchema(ClarifyQuestions.jsonSchema)
    }

    /// The schema names `suggested_answers`; the decoder converts snake_case. If the schema
    /// were changed to camelCase the model's output would silently lose the field.
    @Test func schemaFieldNamesMatchWhatTheDecoderExpects() throws {
        guard case .object(let root) = ClarifyQuestions.jsonSchema,
              case .object(let props)? = root["properties"],
              case .object(let questions)? = props["questions"],
              case .object(let items)? = questions["items"],
              case .object(let itemProps)? = items["properties"] else {
            Issue.record("schema shape changed"); return
        }
        #expect(Set(itemProps.keys) == ["id", "question", "why", "suggested_answers"])
        // Round-trip a payload shaped exactly like the schema through the real decoder.
        let payload = #"{"questions":[{"id":"q1","question":"Who reads this?","why":"changes tone","suggested_answers":["client","team"]}]}"#
        let q = try RequestCoding.decoder().decode(ClarifyQuestions.self, from: Data(payload.utf8))
        #expect(q.questions.first?.suggestedAnswers == ["client", "team"])
        #expect(q.questions.first?.id == "q1")
    }

    @Test func clampKeepsAtMostThreeQuestionsInOrder() {
        let five = ClarifyQuestions(questions: (1...5).map {
            ClarifyQuestion(id: "q\($0)", question: "Q\($0)?", why: "", suggestedAnswers: [])
        })
        #expect(five.clamped().questions.map(\.id) == ["q1", "q2", "q3"])
        #expect(five.clamped(max: 2).questions.map(\.id) == ["q1", "q2"])
        #expect(five.clamped(max: 99).questions.count == 5)
    }

    @Test func clampLeavesShortSetsAloneAndReportsEmptiness() {
        let one = ClarifyQuestions(questions: [ClarifyQuestion(id: "a", question: "A?", why: "", suggestedAnswers: [])])
        #expect(one.clamped().questions.count == 1)
        #expect(!one.isEmpty)
        #expect(ClarifyQuestions(questions: []).isEmpty)
        #expect(ClarifyQuestions(questions: []).clamped().questions.isEmpty)
    }

    @Test func codableRoundTripUsesTheSameKeysInBothDirections() throws {
        let q = ClarifyQuestions(questions: [
            ClarifyQuestion(id: "a", question: "A?", why: "w", suggestedAnswers: ["x", "y"]),
        ])
        // Plain coder pair, as the harness uses when writing and reloading case.json.
        let data = try JSONEncoder().encode(q)
        #expect(try JSONDecoder().decode(ClarifyQuestions.self, from: data) == q)
        // The API-facing pair.
        let apiData = try RequestCoding.encoder().encode(q)
        #expect(String(data: apiData, encoding: .utf8)!.contains("suggested_answers"))
        #expect(try RequestCoding.decoder().decode(ClarifyQuestions.self, from: apiData) == q)
    }

    @Test func answersCarryTheQuestionTextForTheRewritePrompt() {
        let a = ClarifyAnswer(questionID: "q1", question: "Who reads this?", answer: "the client")
        #expect(a.questionID == "q1")
        #expect(a.question == "Who reads this?")
        #expect(a.answer == "the client")
    }
}
