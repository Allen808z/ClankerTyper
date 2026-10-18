import AppKit
import Carbon

/// The key held to talk. Adding Shift to it gives command mode; double-tapping it gives
/// hands-free mode.
enum TalkKey: String, CaseIterable, Identifiable {
    case controlOption
    case fn
    case rightOption
    case rightCommand

    var id: Self { self }

    var label: String {
        switch self {
        case .controlOption: return "⌃ Control + ⌥ Option"
        case .fn: return "Fn (🌐)"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        }
    }

    /// Short form for menus and hints.
    var symbol: String {
        switch self {
        case .controlOption: return "⌃⌥"
        case .fn: return "Fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        }
    }

    /// Device-specific bits in a modifier flags value, telling left and right keys apart.
    private static let rightCommandBit: UInt = 0x10
    private static let rightOptionBit: UInt = 0x40

    /// True when this key (and no conflicting modifier) is down. Shift may be added for
    /// command mode. `raw` is `NSEvent.modifierFlags.rawValue`, which keeps the side bits.
    func isHeld(raw: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let command = flags.contains(.command)
        switch self {
        case .controlOption:
            return control && option && !command
        case .fn:
            return flags.contains(.function) && !control && !option && !command
        case .rightOption:
            return raw & Self.rightOptionBit != 0 && !control && !command
        case .rightCommand:
            return raw & Self.rightCommandBit != 0 && !control && !option
        }
    }

    /// Something the user has to change in macOS for this key to work well, if anything.
    var setupNote: String? {
        switch self {
        case .fn:
            return "In System Settings → Keyboard, set “Press 🌐 key to” to “Do Nothing”, so macOS doesn't also react to it."
        case .rightCommand, .rightOption:
            return "Pressing another key while holding it (for example ⌘C) counts as a normal shortcut, and nothing is recorded."
        case .controlOption:
            return nil
        }
    }
}

/// A key with modifiers, as recorded by the user for an action shortcut.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Device-independent `NSEvent.ModifierFlags` raw value: Control, Option, Shift, Command.
    var modifiers: UInt
    /// The key as shown to the user, for example "V" or "F5".
    var key: String

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection([.control, .option, .shift, .command])
    }

    /// How Carbon's RegisterEventHotKey wants the modifiers.
    var carbonModifiers: UInt32 {
        var value: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }

    /// The usual macOS order: ⌃⌥⇧⌘ then the key.
    var display: String {
        let flags = modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }

    /// A global shortcut needs Control, Option or Command; Shift alone would steal typing.
    var isUsable: Bool {
        !modifierFlags.intersection([.control, .option, .command]).isEmpty
    }

    static func controlOption(_ keyCode: Int, _ key: String) -> KeyCombo {
        KeyCombo(keyCode: UInt32(keyCode), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: key)
    }

    /// Builds a combo from a key press, or nil for a modifier-only or unusable press.
    static func from(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> KeyCombo? {
        let modifiers = flags.intersection([.control, .option, .shift, .command])
        let combo = KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers.rawValue,
                             key: keyName(keyCode: keyCode, characters: characters))
        return combo.isUsable ? combo : nil
    }

    /// A readable name for the key: letters and digits as typed, named keys by name.
    static func keyName(keyCode: UInt16, characters: String?) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(keyCode)] { return name }
        let typed = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return typed.isEmpty ? "Key \(keyCode)" : typed
    }
}

extension HotKey.Shortcut {
    var title: String {
        switch self {
        case .pasteLast: return "Paste last transcript"
        case .fixGrammar: return "Fix grammar of highlighted text"
        case .improveWriting: return "Improve writing of highlighted text"
        case .undoLast: return "Undo last dictation"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .pasteLast: return .controlOption(kVK_ANSI_V, "V")
        case .fixGrammar: return .controlOption(kVK_ANSI_G, "G")
        case .improveWriting: return .controlOption(kVK_ANSI_E, "E")
        case .undoLast: return .controlOption(kVK_ANSI_Z, "Z")
        }
    }
}

extension AppSettings {
    static var talkKey: TalkKey {
        get { TalkKey(rawValue: defaults.string(forKey: Key.talkKey) ?? "") ?? .controlOption }
        set { defaults.set(newValue.rawValue, forKey: Key.talkKey) }
    }

    static func combo(for shortcut: HotKey.Shortcut) -> KeyCombo {
        guard let data = defaults.data(forKey: Key.shortcutPrefix + "\(shortcut)"),
              let combo = try? JSONDecoder().decode(KeyCombo.self, from: data), combo.isUsable else {
            return shortcut.defaultCombo
        }
        return combo
    }

    static func setCombo(_ combo: KeyCombo?, for shortcut: HotKey.Shortcut) {
        let key = Key.shortcutPrefix + "\(shortcut)"
        if let combo, combo != shortcut.defaultCombo, let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The action already using `combo`, other than `shortcut` itself.
    static func conflict(for combo: KeyCombo, excluding shortcut: HotKey.Shortcut) -> HotKey.Shortcut? {
        HotKey.Shortcut.allCases.first { $0 != shortcut && Self.combo(for: $0).keyCode == combo.keyCode
            && Self.combo(for: $0).modifierFlags == combo.modifierFlags }
    }

    /// Short start and stop sounds while recording.
    static var playSounds: Bool {
        get { defaults.object(forKey: Key.playSounds) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }
}
