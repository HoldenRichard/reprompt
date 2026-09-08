import Foundation

public struct ClarifyQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var question: String
    public var why: String
    public var suggestedAnswers: [String]
    public init(id: String, question: String, why: String, suggestedAnswers: [String]) {
        self.id = id
        self.question = question
        self.why = why
        self.suggestedAnswers = suggestedAnswers
    }
}

public struct ClarifyQuestions: Codable, Sendable, Equatable {
    public var questions: [ClarifyQuestion]
    public init(questions: [ClarifyQuestion]) { self.questions = questions }

    /// JSON schema for structured output. `minItems`/`maxItems` are not supported, so the
    /// prompt asks for 2-3 and `clamped()` enforces it.
    public static let jsonSchema: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["questions"],
        "properties": [
            "questions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["id", "question", "why", "suggested_answers"],
                    "properties": [
                        "id": ["type": "string"],
                        "question": ["type": "string"],
                        "why": ["type": "string"],
                        "suggested_answers": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ],
        ],
    ]

    /// The schema cannot express "2 to 3 items", so the count is enforced here. There is
    /// no floor: questions cannot be invented, and callers handle an empty set.
    public func clamped(max: Int = 3) -> ClarifyQuestions {
        ClarifyQuestions(questions: Array(questions.prefix(max)))
    }

    public var isEmpty: Bool { questions.isEmpty }
}

public struct ClarifyAnswer: Codable, Sendable, Equatable {
    public var questionID: String
    public var question: String
    public var answer: String
    public init(questionID: String, question: String, answer: String) {
        self.questionID = questionID
        self.question = question
        self.answer = answer
    }
}
