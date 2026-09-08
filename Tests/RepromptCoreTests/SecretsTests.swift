import Foundation
import Testing
@testable import RepromptCore

@Suite struct APIKeyProviderTests {
    @Test func environmentWinsOverTheKeychain() throws {
        let key = try APIKeyProvider.resolve(environment: ["ANTHROPIC_API_KEY": "sk-env"],
                                             keychain: { "sk-keychain" })
        #expect(key == "sk-env")
    }

    @Test func surroundingWhitespaceIsTrimmed() throws {
        #expect(try APIKeyProvider.resolve(environment: ["ANTHROPIC_API_KEY": "  sk-x \n"], keychain: { nil }) == "sk-x")
        #expect(try APIKeyProvider.resolve(environment: [:], keychain: { " sk-y " }) == "sk-y")
    }

    @Test func anEmptyOrBlankEnvironmentValueFallsThroughToTheKeychain() throws {
        #expect(try APIKeyProvider.resolve(environment: ["ANTHROPIC_API_KEY": ""], keychain: { "sk-kc" }) == "sk-kc")
        #expect(try APIKeyProvider.resolve(environment: ["ANTHROPIC_API_KEY": "   "], keychain: { "sk-kc" }) == "sk-kc")
    }

    @Test func noKeyAnywhereIsATypedError() {
        #expect(throws: ClaudeError.missingAPIKey) {
            try APIKeyProvider.resolve(environment: [:], keychain: { nil })
        }
        #expect(throws: ClaudeError.missingAPIKey) {
            try APIKeyProvider.resolve(environment: [:], keychain: { "  " })
        }
    }

    @Test func aKeychainFailurePropagatesRatherThanLookingLikeAMissingKey() {
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try APIKeyProvider.resolve(environment: [:], keychain: { throw Boom() })
        }
    }

    /// The redacted form is shown in Settings. It must never print a character twice or
    /// reveal the middle of a short key.
    @Test func redactionShowsOnlyTheEndsOfALongKey() {
        #expect(APIKeyProvider.redacted("sk-ant-api03-abcdefgh1234") == "sk-ant...1234")
        let full = "sk-ant-api03-abcdefgh1234"
        let shown = APIKeyProvider.redacted(full)
        #expect(!shown.contains("api03"))
        #expect(shown.count < full.count)
    }

    @Test func shortKeysAreMaskedEntirely() {
        for key in ["", "abc", "12345678", "12345678901"] {
            let r = APIKeyProvider.redacted(key)
            #expect(r.allSatisfy { $0 == "*" }, "\(key.debugDescription) leaked as \(r)")
            #expect(r.count >= 4)
        }
        #expect(APIKeyProvider.redacted("123456789012") == "123456...9012")
    }

    @Test func theEnvironmentVariableNameIsTheDocumentedOne() {
        #expect(APIKeyProvider.environmentVariable == "ANTHROPIC_API_KEY")
    }
}

@Suite(.serialized) struct KeychainStoreTests {
    /// A scratch service per test run, so the user's real stored key is never touched.
    let service = "com.holdenrichard.reprompt.tests.\(UUID().uuidString)"
    let account = "test-account"

    func cleanup() { try? KeychainStore.delete(service: service, account: account) }

    @Test func savesReadsAndDeletesRoundTrip() throws {
        defer { cleanup() }
        #expect(try KeychainStore.read(service: service, account: account) == nil)
        do {
            try KeychainStore.save("sk-first", service: service, account: account)
        } catch {
            // Some CI keychains refuse writes outright; that is an environment limit, not a defect.
            Issue.record("keychain unavailable in this environment: \(error)")
            return
        }
        #expect(try KeychainStore.read(service: service, account: account) == "sk-first")
        try KeychainStore.delete(service: service, account: account)
        #expect(try KeychainStore.read(service: service, account: account) == nil)
    }

    /// Regression: save() used to delete the existing item first, so a failure between the
    /// delete and the add left the user with no key at all.
    @Test func savingTwiceReplacesTheValueAndKeepsExactlyOneItem() throws {
        defer { cleanup() }
        do {
            try KeychainStore.save("sk-first", service: service, account: account)
        } catch {
            Issue.record("keychain unavailable in this environment: \(error)")
            return
        }
        try KeychainStore.save("sk-second", service: service, account: account)
        #expect(try KeychainStore.read(service: service, account: account) == "sk-second")

        // Exactly one item, so reads are not ambiguous.
        var q = KeychainStore.baseQuery(service: service, account: account)
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        q[kSecReturnAttributes as String] = true
        var items: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &items)
        #expect(status == errSecSuccess)
        #expect((items as? [Any])?.count == 1)
    }

    @Test func deletingWhenNothingIsStoredSucceeds() throws {
        #expect(throws: Never.self) { try KeychainStore.delete(service: service, account: account) }
    }

    @Test func unicodeValuesSurviveTheRoundTrip() throws {
        defer { cleanup() }
        let value = "sk-ünïcødé-🎯-key"
        do {
            try KeychainStore.save(value, service: service, account: account)
        } catch {
            Issue.record("keychain unavailable in this environment: \(error)")
            return
        }
        #expect(try KeychainStore.read(service: service, account: account) == value)
    }

    @Test func productionServiceAndAccountAreTheDocumentedOnes() {
        #expect(KeychainStore.service == "com.holdenrichard.reprompt")
        #expect(KeychainStore.account == "anthropic-api-key")
    }
}
