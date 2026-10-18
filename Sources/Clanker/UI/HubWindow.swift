import AppKit
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, snippets, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class HubModel: ObservableObject {
    @Published var page: HubPage = .home
}

/// Clanker's main window.
@MainActor
final class HubWindowController {
    private let model = HubModel()
    private let store: ClankerStore
    private let permissions: PermissionState
    private var window: NSWindow?

    init(store: ClankerStore, permissions: PermissionState) {
        self.store = store
        self.permissions = permissions
    }

    func show(_ page: HubPage) {
        model.page = page
        if window == nil {
            let root = HubView(model: model, store: store, permissions: permissions)
            let created = NSWindow(contentViewController: NSHostingController(rootView: root))
            created.title = "Clanker"
            created.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            created.setContentSize(NSSize(width: 920, height: 640))
            created.minSize = NSSize(width: 760, height: 520)
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        permissions.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HubView: View {
    @ObservedObject var model: HubModel
    @ObservedObject var store: ClankerStore
    let permissions: PermissionState

    var body: some View {
        NavigationSplitView {
            List(HubPage.allCases, selection: Binding(get: { model.page }, set: { if let page = $0 { model.page = page } })) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.page {
            case .home: HomePage(store: store, model: model)
            case .history: HistoryPage(store: store)
            case .dictionary: DictionaryPage(store: store)
            case .snippets: SnippetsPage(store: store)
            case .settings: SettingsView(permissions: permissions)
            }
        }
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var store: ClankerStore
    @ObservedObject var model: HubModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Speak, and it's typed.")
                    .font(.system(size: 26, weight: .bold))
                Text("Hold ⌃ Control + ⌥ Option anywhere and talk. Release, and your words land where your cursor is.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    StatTile(value: "\(store.totalWords)", label: "words dictated")
                    StatTile(value: "\(store.averageWordsPerMinute)", label: "words per minute")
                    StatTile(value: "\(store.wordsThisWeek)", label: "words this week")
                    StatTile(value: "\(store.learnedCount)", label: "words learned")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shortcuts").font(.headline)
                    ShortcutRow(keys: "Hold ⌃⌥", action: "Dictate while held")
                    ShortcutRow(keys: "Double-tap ⌃⌥", action: "Hands-free: talk without holding, tap again to stop")
                    ShortcutRow(keys: "⌃⌥V", action: "Paste the last transcript again")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text("Recent").font(.headline)
                    Spacer()
                    if !store.history.isEmpty {
                        Button("See all") { model.page = .history }
                            .buttonStyle(.link)
                    }
                }
                if store.history.isEmpty {
                    Text("Nothing yet. Your dictations will appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.history.prefix(5)) { item in
                        HistoryRow(item: item, onDelete: nil)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

private struct StatTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .frame(width: 130, alignment: .leading)
            Text(action)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - History

private struct HistoryPage: View {
    @ObservedObject var store: ClankerStore
    @State private var search = ""
    @State private var confirmClear = false

    private var items: [HistoryItem] {
        guard !search.isEmpty else { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.system(size: 22, weight: .bold))
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Clear all", role: .destructive) { confirmClear = true }
                    .disabled(store.history.isEmpty)
            }
            .padding(20)

            if items.isEmpty {
                Text(search.isEmpty ? "Nothing dictated yet." : "No dictation matches “\(search)”.")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                List(items) { item in
                    HistoryRow(item: item) { store.deleteHistory(item.id) }
                }
            }
        }
        .alert("Delete all history?", isPresented: $confirmClear) {
            Button("Delete all", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your dictation history is removed from this Mac. Your dictionary and snippets are kept.")
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(item.date, format: .dateTime.day().month().hour().minute())
                if let app = item.appName {
                    Text("·")
                    Text(app)
                }
                Text("·")
                Text("\(item.words) words")
                if item.outcome != "pasted" {
                    Text("· clipboard only")
                }
                Spacer()
                Button {
                    TextInsertion.putOnClipboard(item.text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(item.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @ObservedObject var store: ClankerStore
    @State private var newWord = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictionary").font(.system(size: 22, weight: .bold))
                    Text("Names, brands and jargon Clanker should recognize. When you correct a pasted word that isn't everyday vocabulary, Clanker learns it here; delete anything it got wrong.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Words to recognize") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Add a word, for example Clanker", text: $newWord)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addWord)
                            Button("Add", action: addWord)
                                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if store.vocabulary.isEmpty {
                            Text("No words yet.").foregroundStyle(.secondary)
                        }
                        ForEach(store.vocabulary) { word in
                            HStack {
                                Text(word.word)
                                if word.learned { LearnedBadge() }
                                Spacer()
                                Button { store.deleteWord(word.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help(word.learned ? "Forget this learned word" : "Delete")
                            }
                        }
                    }
                    .padding(8)
                }

                GroupBox("Replacements") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When Clanker hears the first, it types the second.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Heard", text: $newFrom)
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            TextField("Type instead", text: $newTo)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addReplacement)
                            Button("Add", action: addReplacement)
                                .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                                          || newTo.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if store.replacements.isEmpty {
                            Text("No replacements yet.").foregroundStyle(.secondary)
                        }
                        ForEach(store.replacements) { replacement in
                            HStack {
                                Text(replacement.from).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(replacement.to)
                                if replacement.learned { LearnedBadge() }
                                Spacer()
                                Button { store.deleteReplacement(replacement.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help(replacement.learned ? "Undo this learned correction" : "Delete")
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private func addWord() {
        store.addWord(newWord)
        newWord = ""
    }

    private func addReplacement() {
        store.addReplacement(from: newFrom, to: newTo)
        newFrom = ""
        newTo = ""
    }
}

private struct LearnedBadge: View {
    var body: some View {
        Text("Learned")
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Brand.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(Brand.accent)
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    @ObservedObject var store: ClankerStore
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snippets").font(.system(size: 22, weight: .bold))
                    Text("Say a short phrase and Clanker types the full text: an address, a link, a signature.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("New snippet") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("When I say… (for example “my email”)", text: $trigger)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $expansion)
                            .font(.body)
                            .frame(minHeight: 70)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Text("Type this instead").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Add snippet") {
                                store.addSnippet(trigger: trigger, expansion: expansion)
                                trigger = ""
                                expansion = ""
                            }
                            .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
                        }
                    }
                    .padding(8)
                }

                if store.snippets.isEmpty {
                    Text("No snippets yet.").foregroundStyle(.secondary)
                }
                ForEach(store.snippets) { snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("“\(snippet.trigger)”").font(.headline)
                            Text(snippet.expansion)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button { store.deleteSnippet(snippet.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}
