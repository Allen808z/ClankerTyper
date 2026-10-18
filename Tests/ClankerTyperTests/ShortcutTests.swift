import AppKit
import Carbon
import Testing
@testable import ClankerTyper

@Suite("Talk key and shortcuts")
struct ShortcutTests {
    private let control = NSEvent.ModifierFlags.control.rawValue
    private let option = NSEvent.ModifierFlags.option.rawValue
    private let command = NSEvent.ModifierFlags.command.rawValue
    private let shift = NSEvent.ModifierFlags.shift.rawValue
    private let function = NSEvent.ModifierFlags.function.rawValue
    // Side bits macOS adds to modifier flags.
    private let rightCommandBit: UInt = 0x10, leftCommandBit: UInt = 0x08
    private let rightOptionBit: UInt = 0x40, leftOptionBit: UInt = 0x20

    @Test func controlOptionWithOrWithoutShift() {
        #expect(TalkKey.controlOption.isHeld(raw: control | option))
        #expect(TalkKey.controlOption.isHeld(raw: control | option | shift))
        #expect(!TalkKey.controlOption.isHeld(raw: control | option | command))
        #expect(!TalkKey.controlOption.isHeld(raw: control))
    }

    @Test func rightCommandIsNotLeftCommand() {
        #expect(TalkKey.rightCommand.isHeld(raw: command | rightCommandBit))
        #expect(!TalkKey.rightCommand.isHeld(raw: command | leftCommandBit))
        #expect(!TalkKey.rightCommand.isHeld(raw: command | rightCommandBit | option))
    }

    @Test func rightOptionIsNotLeftOption() {
        #expect(TalkKey.rightOption.isHeld(raw: option | rightOptionBit))
        #expect(TalkKey.rightOption.isHeld(raw: option | rightOptionBit | shift))
        #expect(!TalkKey.rightOption.isHeld(raw: option | leftOptionBit))
    }

    @Test func fnAlone() {
        #expect(TalkKey.fn.isHeld(raw: function))
        #expect(!TalkKey.fn.isHeld(raw: function | command))
    }

    @Test func comboDisplayAndCarbonModifiers() {
        let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: control | shift | command, key: "K")
        #expect(combo.display == "⌃⇧⌘K")
        #expect(combo.carbonModifiers == UInt32(controlKey | shiftKey | cmdKey))
        #expect(HotKey.Shortcut.pasteLast.defaultCombo.display == "⌃⌥V")
    }

    @Test func plainKeysAndShiftOnlyAreRejected() {
        #expect(KeyCombo.from(keyCode: UInt16(kVK_ANSI_A), flags: [], characters: "a") == nil)
        #expect(KeyCombo.from(keyCode: UInt16(kVK_ANSI_A), flags: .shift, characters: "A") == nil)
        #expect(KeyCombo.from(keyCode: UInt16(kVK_ANSI_A), flags: [.command, .shift], characters: "a")?.display == "⇧⌘A")
        #expect(KeyCombo.from(keyCode: UInt16(kVK_F5), flags: .control, characters: nil)?.display == "⌃F5")
    }
}

@Suite("Recording sounds")
struct SoundCueTests {
    @Test func wavHasAValidHeaderAndLength() {
        let data = SoundCues.wav(notes: [880, 1318.5], sampleRate: 8000, noteLength: 0.05)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        // 2 notes × 400 samples × 2 bytes, plus the 44-byte header.
        #expect(data.count == 44 + 2 * 400 * 2)
    }
}
