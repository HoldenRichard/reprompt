import Foundation
import Testing
@testable import RepromptCore

@Suite struct ModelCatalogTests {
    @Test func catalogListsTheOfferedModelsWithOpus5Default() {
        #expect(ModelCatalog.all.map(\.id) == ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5-1"])
        #expect(ModelCatalog.default.id == "claude-opus-5")
        #expect(Set(ModelCatalog.all.map(\.id)).count == ModelCatalog.all.count, "duplicate model id")
        for m in ModelCatalog.all {
            #expect(!m.displayName.isEmpty)
            #expect(m.inputPricePerMTok > 0)
            #expect(m.outputPricePerMTok > m.inputPricePerMTok)
            #expect(ModelCatalog.info(for: m.id)?.id == m.id)
        }
    }

    /// The flags exist to stop a rejected parameter reaching the API. These are the
    /// documented per-model rules they encode.
    @Test func capabilityFlagsMatchTheDocumentedAPIRules() {
        #expect(ModelCatalog.opus5.supportsEffort)
        #expect(ModelCatalog.opus5.supportsFastMode, "fast mode is Opus 5 / 4.8 only")
        #expect(ModelCatalog.opus5.thinking == .adaptive(disabledUpToEffort: .high),
                "disabling thinking on Opus 5 is rejected above high effort")

        #expect(ModelCatalog.sonnet5.supportsEffort)
        #expect(!ModelCatalog.sonnet5.supportsFastMode)

        #expect(!ModelCatalog.haiku45.supportsEffort, "effort is rejected on Haiku 4.5")
        #expect(ModelCatalog.haiku45.thinking == .budgetOnly)
        #expect(!ModelCatalog.haiku45.supportsFastMode)

        #expect(ModelCatalog.fable51.thinking == .alwaysOn, "Fable 5.1 rejects thinking: disabled")
        #expect(ModelCatalog.fable51.supportsFallbacks)
        #expect(!ModelCatalog.fable51.supportsFastMode)
    }

    @Test func unknownModelGetsConservativeFlags() {
        let m = ModelCatalog.infoOrGeneric(for: "claude-from-the-future")
        #expect(m.id == "claude-from-the-future")
        #expect(m.displayName == "claude-from-the-future")
        #expect(!m.supportsEffort)
        #expect(!m.supportsFallbacks)
        #expect(!m.supportsFastMode)
        #expect(m.thinking == .budgetOnly)
        #expect(ModelCatalog.info(for: "claude-from-the-future") == nil)
    }

    @Test func effortOrderingIsLowToMax() {
        #expect(Effort.allCases == [.low, .medium, .high, .xhigh, .max])
        #expect(Effort.low.isAtMost(.max))
        #expect(Effort.high.isAtMost(.high))
        #expect(!Effort.xhigh.isAtMost(.high))
        #expect(!Effort.max.isAtMost(.xhigh))
    }

    // MARK: Cost

    @Test func freshInputAndOutputArePricedAtListRate() {
        let c = ModelCatalog.opus5.cost(usage: Usage(inputTokens: 1_000_000, outputTokens: 1_000_000))
        #expect(abs(c - 30) < 1e-9)  // $5 in + $25 out
        let s = ModelCatalog.sonnet5.cost(usage: Usage(inputTokens: 1_000_000, outputTokens: 0))
        #expect(abs(s - 2) < 1e-9)
    }

    @Test func cacheReadsBillAtATenthAndWritesAtOneAndAQuarter() {
        let read = ModelCatalog.opus5.cost(usage: Usage(cacheReadInputTokens: 1_000_000))
        #expect(abs(read - 0.5) < 1e-9)
        let write = ModelCatalog.opus5.cost(usage: Usage(cacheCreationInputTokens: 1_000_000))
        #expect(abs(write - 6.25) < 1e-9)
    }

    /// Regression: `input_tokens` already excludes cache reads, so subtracting them made a
    /// heavily cached request cost a NEGATIVE amount and understated every run's total.
    @Test func aMostlyCachedRequestCostsAPositiveAmount() {
        let u = Usage(inputTokens: 100, outputTokens: 50,
                      cacheCreationInputTokens: 0, cacheReadInputTokens: 20_000)
        let c = ModelCatalog.opus5.cost(usage: u)
        #expect(c > 0, "a cached request must never price negative, got \(c)")
        // 100*5 + 20000*0.5 + 50*25 == 11750 micro-dollars
        #expect(abs(c - 0.011750) < 1e-9)
    }

    @Test func zeroUsageIsFree() {
        #expect(ModelCatalog.opus5.cost(usage: Usage()) == 0)
    }
}
