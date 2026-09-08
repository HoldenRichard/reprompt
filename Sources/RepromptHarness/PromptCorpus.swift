import Foundation
import RepromptCore

/// One prompt file on disk: a small front-matter block, then the prompt text.
struct CorpusPrompt: Codable, Sendable, Equatable {
    var id: String
    var project: String
    var category: String
    var text: String
    var chars: Int { text.count }
}

enum PromptCorpus {
    static func fileName(for p: HarvestedPrompt) -> String {
        let safe = p.project.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return String(format: "%04d-%@.md", p.id, safe)
    }

    static func render(_ p: HarvestedPrompt) -> String {
        var s = "---\n"
        s += "id: \(String(format: "%04d", p.id))\n"
        s += "project: \(p.project)\n"
        s += "category: \(p.category)\n"
        if let t = p.timestamp { s += "timestamp: \(t)\n" }
        s += "chars: \(p.chars)\n"
        s += "sha256: \(p.sha256)\n"
        s += "session_file: \(p.sessionFile)\n"
        s += "---\n"
        s += p.text + "\n"
        return s
    }

    /// Files this writer owns: `NNNN-<project>.md`. Only these are cleared on rewrite, so
    /// a hand-curated file dropped in the same directory survives.
    static func isGeneratedFileName(_ name: String) -> Bool {
        name.range(of: "^[0-9]{4}-.*\\.md$", options: .regularExpression) != nil
    }

    static func write(_ prompts: [HarvestedPrompt], to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Clear the previous harvest so the directory and index.json cannot disagree.
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where isGeneratedFileName(url.lastPathComponent) {
            try fm.removeItem(at: url)
        }
        for p in prompts {
            try render(p).write(to: dir.appendingPathComponent(fileName(for: p)), atomically: true, encoding: .utf8)
        }
        struct IndexEntry: Codable {
            var id: Int; var file: String; var project: String; var category: String
            var chars: Int; var sha256: String; var sessionFile: String; var timestamp: String?
        }
        let index = prompts.map {
            IndexEntry(id: $0.id, file: fileName(for: $0), project: $0.project, category: $0.category,
                       chars: $0.chars, sha256: $0.sha256, sessionFile: $0.sessionFile, timestamp: $0.timestamp)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(index).write(to: dir.appendingPathComponent("index.json"))
    }

    /// Parse one prompt file. Files without front matter are accepted (text only).
    static func parse(file: URL) throws -> CorpusPrompt {
        let raw = try String(contentsOf: file, encoding: .utf8)
        let id = file.deletingPathExtension().lastPathComponent
        var meta: [String: String] = [:]
        var body = raw
        if raw.hasPrefix("---\n") {
            let rest = raw.dropFirst(4)
            if let end = rest.range(of: "\n---\n") {
                for line in rest[..<end.lowerBound].split(separator: "\n") {
                    if let colon = line.firstIndex(of: ":") {
                        let k = line[..<colon].trimmingCharacters(in: .whitespaces)
                        let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        meta[k] = v
                    }
                }
                body = String(rest[end.upperBound...])
            }
        }
        return CorpusPrompt(
            id: id, project: meta["project"] ?? "unknown", category: meta["category"] ?? "misc",
            text: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func load(directory: URL) throws -> [CorpusPrompt] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map(parse(file:))
    }
}
