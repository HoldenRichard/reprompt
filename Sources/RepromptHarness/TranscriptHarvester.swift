import Foundation
import RepromptCore

struct HarvestedPrompt: Codable, Sendable, Equatable {
    var id: Int
    var project: String
    var category: String
    var chars: Int
    var sha256: String
    var sessionFile: String
    var timestamp: String?
    var text: String
}

struct HarvestOptions: Sendable {
    var minChars = 80
    var maxChars = 6000
}

/// Reads Claude Code transcripts (`~/.claude/projects/<dir>/<session>.jsonl`) and extracts
/// the prompts a human typed. Read-only: never writes under the transcript root.
enum TranscriptHarvester {
    static func projectName(fromDir dir: String) -> String {
        var s = dir
        for prefix in ["-Users-holden-Desktop-", "-Users-holden-"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
            break
        }
        while s.hasSuffix("-") { s = String(s.dropLast()) }
        while s.hasPrefix("-") { s = String(s.dropFirst()) }
        return s.isEmpty ? dir : s
    }

    static func category(forProject project: String) -> String {
        let p = project.lowercased()
        if p.contains("kabu") || p.contains("tradesim") { return "ios-app" }
        if p.contains("resume") || p.contains("internship") { return "career-writing" }
        if p.contains("research") || p.contains("caselaw") || p.contains("grs") || p.contains("school") { return "research" }
        if p.contains("hackathon") { return "hackathon" }
        return "misc"
    }

    struct RawPrompt: Sendable { var text: String; var timestamp: String? }

    /// Extract human prompts from one JSONL transcript.
    static func extract(jsonl data: Data, options: HarvestOptions) -> [RawPrompt] {
        var out: [RawPrompt] = []
        for lineData in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any] else { continue }
            guard obj["type"] as? String == "user" else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            guard let origin = obj["origin"] as? [String: Any], origin["kind"] as? String == "human" else { continue }
            guard let message = obj["message"] as? [String: Any] else { continue }
            var text: String
            if let s = message["content"] as? String {
                text = s
            } else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            } else { continue }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("/") else { continue }
            guard text.count >= options.minChars, text.count <= options.maxChars else { continue }
            out.append(RawPrompt(text: text, timestamp: obj["timestamp"] as? String))
        }
        return out
    }

    /// Walk the transcript root, extract, de-duplicate by content hash, number sequentially.
    static func harvest(root: URL, options: HarvestOptions = HarvestOptions()) throws -> [HarvestedPrompt] {
        let fm = FileManager.default
        let projectDirs = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seen = Set<String>()
        var result: [HarvestedPrompt] = []
        for dir in projectDirs {
            let project = projectName(fromDir: dir.lastPathComponent)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for file in files {
                guard let data = fm.contents(atPath: file.path) else { continue }
                for raw in extract(jsonl: data, options: options) {
                    let normalized = raw.text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    let hash = PromptLibrary.sha256(normalized)
                    guard seen.insert(hash).inserted else { continue }
                    result.append(HarvestedPrompt(
                        id: result.count + 1, project: project, category: category(forProject: project),
                        chars: raw.text.count, sha256: hash,
                        sessionFile: dir.lastPathComponent + "/" + file.lastPathComponent,
                        timestamp: raw.timestamp, text: raw.text))
                }
            }
        }
        return result
    }
}
