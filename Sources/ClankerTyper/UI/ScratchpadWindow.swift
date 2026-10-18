import AppKit
import SwiftUI

/// A small floating note. Dictation lands here when there is no text field to type into, and
/// it can be edited, copied or cleared. Its text is saved with the rest of ClankerTyper's data.
@MainActor
final class ScratchpadWindowController {
    private let store: ClankerTyperStore
    private var panel: NSPanel?

    init(store: ClankerTyperStore) {
        self.store = store
    }

    /// - Parameter activate: bring ClankerTyper to the front to type in the note. Off, the note
    ///   appears without taking focus from the app the user is in.
    func show(activate: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scratchpad"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 300, height: 200)
        panel.contentViewController = NSHostingController(rootView: ScratchpadView(store: store))
        if let area = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.maxX - 400, y: area.maxY - 320))
        }
        return panel
    }
}

private struct ScratchpadView: View {
    @ObservedObject var store: ClankerTyperStore
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $store.scratchpad)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(store.scratchpad.isEmpty
                     ? "Dictation lands here when there's no text field to type into."
                     : "\(TextProcessing.wordCount(store.scratchpad)) words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy all") { TextInsertion.putOnClipboard(store.scratchpad) }
                    .disabled(store.scratchpad.isEmpty)
                Button("Clear", role: .destructive) { confirmClear = true }
                    .disabled(store.scratchpad.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(minWidth: 300, minHeight: 200)
        .alert("Clear the scratchpad?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { store.scratchpad = "" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its text is removed from this Mac. History is kept.")
        }
    }
}
