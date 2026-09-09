import ArgumentParser
import Foundation
import RepromptCore

/// Lists the models a provider actually offers this account, and flags where the built-in
/// catalog disagrees. Listing generates no tokens, so this is free to run.
struct ModelsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "List the models the provider currently offers, and check the catalog against them.")

    @Option(name: .long, help: "Which service to ask (anthropic|gemini|groq).")
    var provider: Provider = OptimizerConfig.default.provider

    @Flag(name: .long, help: "Show every model, not just ones that look usable for rewriting.")
    var all = false

    mutating func run() async throws {
        let client = try LLMClientFactory.make(provider: provider)
        let remote = try await client.availableModels()
        guard !remote.isEmpty else {
            print("\(provider.displayName) returned no model list.")
            return
        }
        let shown = all ? remote : remote.filter { !Self.isNoise($0.id) }
        print("\(provider.displayName): \(remote.count) models (\(shown.count) shown)\n")
        for m in shown.sorted(by: { $0.id < $1.id }) {
            let known = ModelCatalog.info(for: m.id) != nil ? " [in catalog]" : ""
            let limits = m.inputTokenLimit.map { " in:\($0)" } ?? ""
            print("  \(m.id)\(limits)\(known)")
        }
        let remoteIDs = Set(remote.map(\.id))
        let missing = ModelCatalog.models(for: provider).map(\.id).filter { !remoteIDs.contains($0) }
        if !missing.isEmpty {
            print("\nIn the catalog but NOT offered by this account: \(missing.joined(separator: ", "))")
            print("Those would fail at request time; the catalog needs updating.")
        }
    }

    /// Embedding, image and audio models cannot answer a rewrite request.
    static func isNoise(_ id: String) -> Bool {
        let l = id.lowercased()
        for marker in ["embedding", "aqa", "imagen", "veo", "tts", "image-generation", "vision-latest", "gemma"] {
            if l.contains(marker) { return true }
        }
        return false
    }
}
