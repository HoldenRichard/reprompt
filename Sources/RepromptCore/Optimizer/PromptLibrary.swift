import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum PromptName: String, CaseIterable, Sendable {
    case optimizer = "optimizer_system"
    case clarifyQuestions = "clarify_questions_system"
    case clarifyFinal = "clarify_final_system"
    case judge = "judge_system"

    public var fileName: String { rawValue + ".md" }

    fileprivate var embedded: [UInt8] {
        switch self {
        case .optimizer: PackageResources.optimizer_system_md
        case .clarifyQuestions: PackageResources.clarify_questions_system_md
        case .clarifyFinal: PackageResources.clarify_final_system_md
        case .judge: PackageResources.judge_system_md
        }
    }
}

public struct SystemPrompt: Sendable, Equatable {
    public let name: PromptName
    public let text: String
    public let sha256: String
    /// Set when loaded from an override directory; nil for the compiled-in copy.
    public let source: URL?

    public var shortHash: String { String(sha256.prefix(12)) }
}

public struct PromptSet: Sendable, Equatable {
    public var optimizer: SystemPrompt
    public var clarifyQuestions: SystemPrompt
    public var clarifyFinal: SystemPrompt
    public var judge: SystemPrompt

    public var all: [SystemPrompt] { [optimizer, clarifyQuestions, clarifyFinal, judge] }
}

public enum PromptLibraryError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    case notUTF8(PromptName)
    public var description: String {
        switch self {
        case .unreadable(let u, let e): "Cannot read \(u.path): \(e)"
        case .notUTF8(let n): "\(n.fileName) is not UTF-8"
        }
    }
}

/// Prompts are compiled into the binary (SwiftPM `embedInCode`) so a hand-assembled .app
/// has nothing to look up at runtime. An override directory lets the harness iterate on
/// prompt files without rebuilding.
public enum PromptLibrary {
    public static func load(_ name: PromptName, overrideDirectory: URL? = nil) throws -> SystemPrompt {
        if let dir = overrideDirectory {
            let url = dir.appendingPathComponent(name.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                let data: Data
                do { data = try Data(contentsOf: url) } catch { throw PromptLibraryError.unreadable(url, "\(error)") }
                guard let text = String(data: data, encoding: .utf8) else { throw PromptLibraryError.notUTF8(name) }
                return SystemPrompt(name: name, text: text, sha256: sha256(data), source: url)
            }
        }
        let bytes = name.embedded
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw PromptLibraryError.notUTF8(name) }
        return SystemPrompt(name: name, text: text, sha256: sha256(Data(bytes)), source: nil)
    }

    public static func loadAll(overrideDirectory: URL? = nil) throws -> PromptSet {
        PromptSet(
            optimizer: try load(.optimizer, overrideDirectory: overrideDirectory),
            clarifyQuestions: try load(.clarifyQuestions, overrideDirectory: overrideDirectory),
            clarifyFinal: try load(.clarifyFinal, overrideDirectory: overrideDirectory),
            judge: try load(.judge, overrideDirectory: overrideDirectory)
        )
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ text: String) -> String { sha256(Data(text.utf8)) }
}
