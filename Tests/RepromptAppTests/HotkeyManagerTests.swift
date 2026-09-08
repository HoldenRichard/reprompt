import Carbon.HIToolbox
import Testing
@testable import Reprompt

/// Registers real global hotkeys, so it uses combinations nothing else plausibly binds
/// (every modifier plus F19/F20) and releases them immediately.
@Suite(.serialized) @MainActor struct HotkeyManagerTests {
    let allModifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    var first: Hotkey { Hotkey(keyCode: UInt32(kVK_F19), carbonModifiers: allModifiers) }
    var second: Hotkey { Hotkey(keyCode: UInt32(kVK_F20), carbonModifiers: allModifiers) }

    @Test func registeringSetsTheCurrentHotkey() throws {
        let m = HotkeyManager()
        defer { m.shutdown() }
        try m.register(first)
        #expect(m.current == first)
    }

    @Test func switchingHotkeysReleasesTheOldOne() throws {
        let m = HotkeyManager()
        defer { m.shutdown() }
        try m.register(first)
        try m.register(second)
        #expect(m.current == second)

        // The first combination must be free again, which only holds if it was released.
        let other = HotkeyManager()
        defer { other.shutdown() }
        #expect(throws: Never.self) { try other.register(first) }
    }

    @Test func registeringTheSameHotkeyTwiceIsANoOp() throws {
        let m = HotkeyManager()
        defer { m.shutdown() }
        try m.register(first)
        #expect(throws: Never.self) { try m.register(first) }
        #expect(m.current == first)
    }

    /// Regression: the old code released the current hotkey BEFORE registering the new one,
    /// so choosing a combination another app already owned left Reprompt with no hotkey at
    /// all, and no way to reach the app to change it back.
    @Test func aRejectedHotkeyLeavesThePreviousOneWorking() throws {
        let occupier = HotkeyManager()
        defer { occupier.shutdown() }
        try occupier.register(second)

        let m = HotkeyManager()
        defer { m.shutdown() }
        try m.register(first)

        #expect(throws: HotkeyError.self) { try m.register(second) }
        #expect(m.current == first, "the working hotkey must survive a rejected change")

        // And it is still actually registered: a third manager cannot claim it.
        let rival = HotkeyManager()
        defer { rival.shutdown() }
        #expect(throws: HotkeyError.self) { try rival.register(first) }
    }

    @Test func unregisteringFreesTheCombination() throws {
        let m = HotkeyManager()
        try m.register(first)
        m.unregisterHotkey()
        #expect(m.current == nil)

        let other = HotkeyManager()
        defer { other.shutdown() }
        #expect(throws: Never.self) { try other.register(first) }
        m.shutdown()
    }

    @Test func shutdownIsSafeToCallWithoutRegistering() {
        let m = HotkeyManager()
        m.shutdown()
        m.shutdown()
        #expect(m.current == nil)
    }
}
