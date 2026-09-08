import ArgumentParser
import Foundation
import RepromptCore

struct HarvestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harvest",
        abstract: "Extract human-typed prompts from Claude Code transcripts into a prompts directory (read-only over the transcripts).")

    @Option(name: .long, help: "Transcript root.", completion: .directory)
    var from: String = NSString(string: "~/.claude/projects").expandingTildeInPath

    @Option(name: .long, help: "Output directory.", completion: .directory)
    var out: String = "prompts/raw"

    @Option(name: .long) var minChars: Int = 80
    @Option(name: .long) var maxChars: Int = 6000

    @Flag(name: .long, help: "Print the table without writing files.") var dryRun = false

    mutating func run() async throws {
        let prompts = try TranscriptHarvester.harvest(
            root: URL(fileURLWithPath: from), options: HarvestOptions(minChars: minChars, maxChars: maxChars))
        if !dryRun {
            try PromptCorpus.write(prompts, to: URL(fileURLWithPath: out))
        }
        var byCategory: [String: Int] = [:]
        var byProject: [String: Int] = [:]
        for p in prompts {
            byCategory[p.category, default: 0] += 1
            byProject[p.project, default: 0] += 1
        }
        let chars = prompts.map { Double($0.chars) }
        print("Harvested \(prompts.count) prompts" + (dryRun ? " (dry run)" : " into \(out)"))
        print(String(format: "Length p50 %.0f, p90 %.0f, max %.0f chars", percentile(chars, 50), percentile(chars, 90), chars.max() ?? 0))
        print("\nBy category:")
        for (k, v) in byCategory.sorted(by: { $0.value > $1.value }) { print(String(format: "  %5d  %@", v, k)) }
        print("\nBy project:")
        for (k, v) in byProject.sorted(by: { $0.value > $1.value }) { print(String(format: "  %5d  %@", v, k)) }
        print("\nNext: read prompts/raw, copy 8-10 spanning the categories into prompts/curated/, and edit the category: line if needed.")
    }
}
