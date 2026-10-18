import AppKit
import SwiftUI

/// What the card is showing right now.
enum CardStatus: Equatable {
    case idle
    case listening(partial: String)
    case thinking
    case reply(String)
    case error(String)
    case transcript(String)
}

@MainActor
final class CardModel: ObservableObject {
    @Published var status: CardStatus = .idle
    @Published var userText: String = ""
    @Published var typed: String = ""
    /// In transcribe-only mode the typed composer is hidden: nothing is sent anywhere.
    @Published var transcribeOnly = false

    /// Set by the controller; called when the user submits typed text.
    var onSubmit: ((String) -> Void)?
    var onClose: (() -> Void)?
}

/// Panel that can take keyboard focus for typing but does not steal focus when it appears.
final class CardPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Escape
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Floating response card in the bottom-right of the screen the mouse is on.
@MainActor
final class ResponseCard {
    let model = CardModel()
    private var panel: CardPanel?

    var isShown: Bool { panel?.isVisible ?? false }

    func show(focus: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> CardPanel {
        model.onClose = { [weak self] in self?.hide() }
        let panel = CardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.onEscape = { [weak self] in self?.hide() }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CardView(model: model))
        return panel
    }

    private func position(_ panel: CardPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = panel.frame.size
        let origin = NSPoint(x: area.maxX - size.width - 24, y: area.minY + 24)
        panel.setFrameOrigin(origin)
    }
}

struct CardView: View {
    @ObservedObject var model: CardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !model.userText.isEmpty {
                Text(model.userText)
                    .font(.system(size: 12))
                    .foregroundStyle(Brand.muted)
                    .lineLimit(2)
            }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            copyButton
            Spacer(minLength: 0)
            if !model.transcribeOnly {
                composer
            }
        }
        .padding(16)
        .frame(width: 380, height: 300, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Brand.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Brand.accent)
                .frame(width: 10, height: 10)
            Text("Clanker")
                .font(.system(size: 13, weight: .semibold))
            Text(statusLabel)
                .font(.system(size: 11))
                .foregroundStyle(Brand.muted)
            Spacer()
            Button {
                model.onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Brand.muted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            switch model.status {
            case .idle:
                Text(model.transcribeOnly
                     ? "Hold Control + Option and talk. Your words appear here."
                     : "Hold Control + Option and ask, or type below.")
                    .foregroundStyle(Brand.muted)
            case .listening(let partial):
                Text(partial.isEmpty ? "Listening…" : partial)
                    .foregroundStyle(partial.isEmpty ? Brand.muted : .white)
            case .thinking:
                Text("Looking at your screen…")
                    .foregroundStyle(Brand.muted)
            case .reply(let text):
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
            case .error(let message):
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .transcript(let text):
                Text(text)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: 150)
    }

    @ViewBuilder
    private var copyButton: some View {
        if case .transcript(let text) = model.status {
            Button("Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .controlSize(.small)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask anything…", text: $model.typed)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(model.typed.trimmingCharacters(in: .whitespaces).isEmpty ? Brand.muted : Brand.accent)
            }
            .buttonStyle(.plain)
            .disabled(model.typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var statusLabel: String {
        switch model.status {
        case .idle: return ""
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .reply: return ""
        case .error: return "needs attention"
        case .transcript: return "transcribed"
        }
    }

    private func submit() {
        let text = model.typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.typed = ""
        model.onSubmit?(text)
    }
}
