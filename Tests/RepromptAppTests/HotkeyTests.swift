import AppKit
import Carbon.HIToolbox
import Testing
@testable import Reprompt

@Suite @MainActor struct HotkeyTests {
    /// NSEvent and Carbon use different modifier encodings. A wrong mapping here silently
    /// registers the wrong combination, so both sides are pinned against the real constants.
    @Test func nsEventModifiersConvertToCarbonModifiers() {
        let command = NSEvent.ModifierFlags.command.rawValue
        let shift = NSEvent.ModifierFlags.shift.rawValue
        let option = NSEvent.ModifierFlags.option.rawValue
        let control = NSEvent.ModifierFlags.control.rawValue

        let cmdShiftR = Hotkey.fromNSEvent(keyCode: UInt16(kVK_ANSI_R), modifierFlagsRaw: command | shift)
        #expect(cmdShiftR == Hotkey.default)
        #expect(cmdShiftR.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(cmdShiftR.keyCode == 15)

        let all = Hotkey.fromNSEvent(keyCode: 0, modifierFlagsRaw: command | shift | option | control)
        #expect(all.carbonModifiers == UInt32(cmdKey | shiftKey | optionKey | controlKey))
    }

    @Test func capsLockAndOtherFlagsAreIgnored() {
        let capsOnly = Hotkey.fromNSEvent(keyCode: 15, modifierFlagsRaw: NSEvent.ModifierFlags.capsLock.rawValue)
        #expect(capsOnly.carbonModifiers == 0)
        #expect(!capsOnly.hasModifier, "a bare key must not be accepted as a global hotkey")
        let fnAndCommand = Hotkey.fromNSEvent(
            keyCode: 15,
            modifierFlagsRaw: NSEvent.ModifierFlags.function.rawValue | NSEvent.ModifierFlags.command.rawValue)
        #expect(fnAndCommand.carbonModifiers == UInt32(cmdKey))
        #expect(fnAndCommand.hasModifier)
    }

    @Test func descriptionUsesTheStandardSymbolsInTheStandardOrder() {
        #expect(Hotkey.default.description == "⇧⌘R")
        let all = Hotkey(keyCode: 15, carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.description == "⌃⌥⇧⌘R")
        #expect(Hotkey(keyCode: 49, carbonModifiers: UInt32(cmdKey)).description == "⌘Space")
        #expect(Hotkey(keyCode: 53, carbonModifiers: UInt32(cmdKey)).description == "⌘⎋")
    }

    @Test func unknownKeyCodesDegradeGracefullyInsteadOfCrashing() {
        #expect(Hotkey.keyName(200) == "key200")
        #expect(Hotkey(keyCode: 200, carbonModifiers: UInt32(cmdKey)).description == "⌘key200")
    }

    @Test func knownKeyNamesMatchTheVirtualKeyCodes() {
        let expected: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_C, "C"), (kVK_ANSI_V, "V"), (kVK_ANSI_R, "R"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_9, "9"), (kVK_Space, "Space"), (kVK_Return, "↩"),
            (kVK_Escape, "⎋"), (kVK_Tab, "⇥"), (kVK_Delete, "⌫"),
            (kVK_F1, "F1"), (kVK_F12, "F12"), (kVK_LeftArrow, "←"), (kVK_UpArrow, "↑"),
        ]
        for (code, name) in expected {
            #expect(Hotkey.keyName(UInt32(code)) == name, "key code \(code)")
        }
    }

    @Test func hotkeysRoundTripThroughTheirStoredForm() throws {
        let h = Hotkey(keyCode: 12, carbonModifiers: UInt32(cmdKey | optionKey))
        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(Hotkey.self, from: data) == h)
    }
}
