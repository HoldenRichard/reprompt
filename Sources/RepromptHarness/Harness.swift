import ArgumentParser
import Foundation
import RepromptCore

@main
struct Harness: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reprompt-harness",
        abstract: "Develop and evaluate the Reprompt optimizer prompt against real prompts.",
        subcommands: subcommandTypes
    )

    /// The Accessibility probe only exists on macOS; everything else runs anywhere.
    static var subcommandTypes: [any ParsableCommand.Type] {
        var list: [any ParsableCommand.Type] = [
            HarvestCommand.self, OptimizeCommand.self, RunCommand.self, JudgeCommand.self, ModelsCommand.self,
        ]
        #if os(macOS)
        list.append(AXProbeCommand.self)
        #endif
        return list
    }
}

// MARK: - Shared helpers

func eprint(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

func fmtMs(_ d: Duration) -> String { String(format: "%.0f ms", ms(d)) }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let s = values.sorted()
    let rank = p / 100 * Double(s.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    if lo == hi { return s[lo] }
    return s[lo] + (s[hi] - s[lo]) * (rank - Double(lo))
}

/// Deterministic RNG so judge A/B ordering is reproducible from a seed.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct CommonModelOptions: ParsableArguments {
    @Option(name: .long, help: "Which service answers (anthropic|gemini|groq).")
    var provider: Provider = OptimizerConfig.default.provider
    @Option(name: .long, help: "Model ID for the optimizer. Defaults to the provider's default.")
    var model: String?
    @Option(name: .long, help: "Effort for Quick mode (low|medium|high|xhigh|max).") var effort: Effort = .low
    @Flag(name: .long, help: "Send thinking: disabled where the model allows it.") var noThinking = false
    @Flag(name: .long, help: "Fast mode (Opus 5 only, 2x price).") var fast = false
    @Option(name: .long, help: "max_tokens for the rewrite.") var maxTokens: Int = 2048
    @Flag(name: .long, help: "Do not send server-side refusal fallbacks.") var noFallbacks = false
    @Option(name: .long, help: "Directory of system prompt overrides (optimizer_system.md, ...).", completion: .directory)
    var promptsDir: String?

    var resolvedModel: String { model ?? ModelCatalog.defaultModel(for: provider).id }

    func config(model override: String? = nil) -> OptimizerConfig {
        OptimizerConfig(
            provider: provider, model: override ?? resolvedModel,
            quickEffort: effort, clarifyEffort: .medium, maxTokens: maxTokens,
            quickThinking: noThinking ? .disabled : .adaptive, fastMode: fast, useFallbacks: !noFallbacks)
    }
    func prompts() throws -> PromptSet {
        try PromptLibrary.loadAll(overrideDirectory: promptsDir.map { URL(fileURLWithPath: $0) })
    }
    func client() throws -> any LLMClient { try LLMClientFactory.make(provider: provider) }
}

extension Effort: ExpressibleByArgument {}
extension Provider: ExpressibleByArgument {}
