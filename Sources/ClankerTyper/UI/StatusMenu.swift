import AppKit

/// Menu bar item. ClankerTyper has no Dock icon; the main window opens from here.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    var onOpenHub: (() -> Void)?
    var onUndoLast: (() -> Void)?
    var onOpenScratchpad: (() -> Void)?
    var onSelectionAction: ((Rewriter.Style) -> Void)?
    var onManageActions: (() -> Void)?
    /// The user's saved actions, read each time the submenu opens.
    var customActions: (() -> [CustomAction])?
    var onPasteLast: (() -> Void)?
    var onFixGrammar: (() -> Void)?
    var onImproveWriting: (() -> Void)?
    var onAsk: (() -> Void)?
    var onSettings: (() -> Void)?
    var onPermissions: (() -> Void)?
    var onToggleCompanion: ((Bool) -> Void)?
    var onToggleSpeech: ((Bool) -> Void)?
    var onToggleTranscribeOnly: ((Bool) -> Void)?
    var onToggleLanguage: ((String, Bool) -> Void)?

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let companionItem = NSMenuItem(title: "Show companion", action: #selector(toggleCompanion), keyEquivalent: "")
    private let speechItem = NSMenuItem(title: "Speak replies", action: #selector(toggleSpeech), keyEquivalent: "")
    private let transcribeItem = NSMenuItem(title: "Transcribe only (no screen)", action: #selector(toggleTranscribeOnly), keyEquivalent: "")
    private var askItem: NSMenuItem?
    private var hintItem: NSMenuItem?
    private var languageItems: [NSMenuItem] = []
    private let selectionMenu = NSMenu(title: "Highlighted text")
    static let readyHint = "Hold ⌃⌥ to talk"

    override init() {
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "ClankerTyper")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let hint = NSMenuItem(title: Self.readyHint, action: nil, keyEquivalent: "")
        hint.isEnabled = false
        hintItem = hint
        menu.addItem(hint)
        menu.addItem(makeItem("Open ClankerTyper…", #selector(openHub), "o"))
        let pasteLast = makeItem("Paste last transcript", #selector(pasteLastTranscript), "v")
        pasteLast.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(pasteLast)
        let undo = makeItem("Undo last dictation", #selector(undoLast), "z")
        undo.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(undo)
        menu.addItem(makeItem("Open Scratchpad", #selector(openScratchpad), ""))
        menu.addItem(.separator())
        let fix = makeItem("Fix grammar of selection", #selector(fixGrammar), "g")
        fix.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(fix)
        let improve = makeItem("Improve writing of selection", #selector(improveWriting), "e")
        improve.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(improve)
        selectionMenu.delegate = self
        let selectionRoot = NSMenuItem(title: "More for highlighted text", action: nil, keyEquivalent: "")
        selectionRoot.submenu = selectionMenu
        menu.addItem(selectionRoot)
        let ask = makeItem("Ask by typing…", #selector(ask), "k")
        askItem = ask
        menu.addItem(ask)
        menu.addItem(.separator())
        companionItem.target = self
        speechItem.target = self
        transcribeItem.target = self
        menu.addItem(transcribeItem)
        let languageMenu = NSMenu()
        for option in AppSettings.languageOptions {
            let languageItem = NSMenuItem(title: option.label, action: #selector(toggleLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = option.id
            languageMenu.addItem(languageItem)
            languageItems.append(languageItem)
        }
        let languageRoot = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageRoot.submenu = languageMenu
        menu.addItem(languageRoot)
        menu.addItem(companionItem)
        menu.addItem(speechItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Permissions…", #selector(permissions), ""))
        menu.addItem(makeItem("Settings…", #selector(settings), ","))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit ClankerTyper", #selector(quit), "q"))
        item.menu = menu
    }

    /// Shows a short status (listening, an error, what was typed) on the top line of the menu.
    func setStatus(_ text: String) {
        hintItem?.title = text
    }

    func refresh(showCompanion: Bool, speakReplies: Bool, transcribeOnly: Bool) {
        companionItem.state = showCompanion ? .on : .off
        speechItem.state = speakReplies ? .on : .off
        transcribeItem.state = transcribeOnly ? .on : .off
        askItem?.isHidden = transcribeOnly
        let selected = AppSettings.dictationLanguages
        for languageItem in languageItems {
            let id = languageItem.representedObject as? String ?? ""
            languageItem.state = selected.contains(id) ? .on : .off
        }
    }

    /// Languages can be combined; the last one cannot be turned off.
    @objc private func toggleLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onToggleLanguage?(id, sender.state != .on)
    }

    @objc private func openHub() { onOpenHub?() }
    @objc private func pasteLastTranscript() { onPasteLast?() }
    @objc private func fixGrammar() { onFixGrammar?() }
    @objc private func undoLast() { onUndoLast?() }
    @objc private func openScratchpad() { onOpenScratchpad?() }

    /// Rebuilt each time it opens, so new saved actions show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === selectionMenu else { return }
        menu.removeAllItems()
        for style in Rewriter.Style.selectionActions where style != .grammar && style != .improve {
            menu.addItem(ClosureMenuItem(style.title) { [weak self] in self?.onSelectionAction?(style) })
        }
        let custom = customActions?() ?? []
        if !custom.isEmpty {
            menu.addItem(.separator())
            for action in custom {
                menu.addItem(ClosureMenuItem(action.name) { [weak self] in self?.onSelectionAction?(.custom(action.instruction)) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Manage actions…") { [weak self] in self?.onManageActions?() })
    }
    @objc private func improveWriting() { onImproveWriting?() }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func ask() { onAsk?() }
    @objc private func settings() { onSettings?() }
    @objc private func permissions() { onPermissions?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleCompanion() {
        onToggleCompanion?(companionItem.state != .on)
    }

    @objc private func toggleSpeech() {
        onToggleSpeech?(speechItem.state != .on)
    }

    @objc private func toggleTranscribeOnly() {
        onToggleTranscribeOnly?(transcribeItem.state != .on)
    }
}
