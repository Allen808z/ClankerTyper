import Foundation
import Testing
@testable import Clanker

@Suite("Saved history, dictionary and snippets")
@MainActor
struct StoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clanker-tests-\(UUID().uuidString)")
    }

    @Test func survivesRelaunch() {
        let dir = temporaryDirectory()
        let store = ClankerStore(directory: dir)
        store.addHistory(HistoryItem(date: Date(), rawText: "um hi", text: "Hi", appName: "Notes", duration: 2, words: 1, outcome: "pasted"))
        store.addWord("Clanker")
        store.addSnippet(trigger: "my email", expansion: "a@b.c")

        let reopened = ClankerStore(directory: dir)
        #expect(reopened.history.map(\.text) == ["Hi"])
        #expect(reopened.vocabulary.map(\.word) == ["Clanker"])
        #expect(reopened.snippets.map(\.trigger) == ["my email"])
    }

    @Test func learningAddsReplacementAndHintOnce() {
        let store = ClankerStore(directory: temporaryDirectory())
        let correction = TextProcessing.Correction(heard: "clinker", corrected: "Clanker")
        #expect(store.learn(correction))
        #expect(!store.learn(correction))
        #expect(store.replacements.count == 1)
        #expect(store.replacements.first?.learned == true)
        #expect(store.recognitionHints == ["Clanker"])
    }

    @Test func newerCorrectionReplacesOlder() {
        let store = ClankerStore(directory: temporaryDirectory())
        store.learn(.init(heard: "clinker", corrected: "Clanka"))
        store.learn(.init(heard: "clinker", corrected: "Clanker"))
        #expect(store.replacements.map(\.to) == ["Clanker"])
    }

    @Test func unreadableFileIsKeptAside() throws {
        let dir = temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        let store = ClankerStore(directory: dir)
        #expect(store.history.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.hasPrefix("store-unreadable-") })
    }

    @Test func statsCountWordsAndSpeed() {
        let store = ClankerStore(directory: temporaryDirectory())
        store.addHistory(HistoryItem(date: Date(), rawText: "", text: "", appName: nil, duration: 30, words: 60, outcome: "pasted"))
        store.addHistory(HistoryItem(date: Date(), rawText: "", text: "", appName: nil, duration: 30, words: 40, outcome: "pasted"))
        #expect(store.totalWords == 100)
        #expect(store.averageWordsPerMinute == 100)
    }
}
