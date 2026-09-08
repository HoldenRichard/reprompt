import Foundation
import Testing
@testable import RepromptCore

@Suite struct JSONValueTests {
    func encode(_ v: JSONValue, snakeCase: Bool = false) throws -> String {
        let e = snakeCase ? RequestCoding.encoder() : JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        if snakeCase { e.keyEncodingStrategy = .convertToSnakeCase }
        return String(data: try e.encode(v), encoding: .utf8)!
    }

    @Test func encodesEachKind() throws {
        #expect(try encode(.string("a")) == "\"a\"")
        #expect(try encode(.bool(true)) == "true")
        #expect(try encode(.null) == "null")
        #expect(try encode(.array([1, 2])) == "[1,2]")
        #expect(try encode(.object(["k": "v"])) == "{\"k\":\"v\"}")
    }

    /// Whole numbers must serialize without a `.0`, or a JSON Schema `maxLength: 3.0`
    /// would be rejected as a non-integer.
    @Test func integralNumbersEncodeWithoutADecimalPoint() throws {
        #expect(try encode(.number(3)) == "3")
        #expect(try encode(.number(-17)) == "-17")
        #expect(try encode(.number(0)) == "0")
        #expect(try encode(.number(2.5)) == "2.5")
        #expect(try encode(.number(1e20)).contains("e+20"))
    }

    @Test func roundTripsThroughEncodeAndDecode() throws {
        let original: JSONValue = [
            "type": "object",
            "count": 3,
            "ratio": 0.25,
            "flag": false,
            "missing": .null,
            "list": ["a", 1, true],
            "nested": ["deep": ["deeper": "yes"]],
        ]
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(back == original)
    }

    /// The snake_case strategy must not rewrite JSON Schema keys such as
    /// `additionalProperties`; if it did, every structured-output call would 400.
    @Test func dictionaryKeysSurviveTheSnakeCaseEncoder() throws {
        let v: JSONValue = ["additionalProperties": false, "suggested_answers": 1]
        let s = try encode(v, snakeCase: true)
        #expect(s.contains("\"additionalProperties\""))
        #expect(!s.contains("additional_properties"))
        #expect(s.contains("\"suggested_answers\""))
    }

    @Test func literalConformancesBuildTheExpectedValues() {
        let v: JSONValue = ["a": 1, "b": ["x", true], "c": 1.5, "d": "s"]
        #expect(v == .object(["a": .number(1), "b": .array([.string("x"), .bool(true)]),
                              "c": .number(1.5), "d": .string("s")]))
    }

    @Test func decodesBoolsAsBoolsNotNumbers() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data("[true,1,0,false]".utf8))
        #expect(v == .array([.bool(true), .number(1), .number(0), .bool(false)]))
    }

    @Test func equalityIgnoresDictionaryOrdering() {
        #expect(JSONValue.object(["a": 1, "b": 2]) == .object(["b": 2, "a": 1]))
    }
}
