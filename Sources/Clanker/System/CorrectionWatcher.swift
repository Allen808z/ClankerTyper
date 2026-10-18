import ApplicationServices
import Foundation

/// After a paste, watches the text field to see whether the user corrects any of the pasted
/// words. It reads the field's text through Accessibility until the user moves to another
/// field, stops editing for a while, or two minutes pass, then reports word-for-word
/// corrections. Apps that do not expose their text (many web views) cannot be watched.
@MainActor
final class CorrectionWatcher {
    var onCorrections: (([TextProcessing.Correction]) -> Void)?

    /// Stop once the user has not changed anything for this long after editing.
    static let idleAfterEdit: TimeInterval = 8
    static let maxWatch: TimeInterval = 120

    private var task: Task<Void, Never>?

    func watch(element: AXUIElement, inserted: String) {
        task?.cancel()
        task = Task { [weak self] in
            // Let the paste reach the field before taking the "before" picture.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let initial = FocusTracker.value(element), initial.contains(inserted) else {
                AppLog.write("correction watch skipped: the field's text is not readable or does not contain the paste")
                return
            }

            var latest = initial
            var lastChange = Date()
            let started = Date()
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                if let value = FocusTracker.value(element), value != latest {
                    latest = value
                    lastChange = Date()
                }
                let stillThere = FocusTracker.isSame(FocusTracker.focusedElement(), element)
                let edited = latest != initial
                if !stillThere
                    || Date().timeIntervalSince(started) > Self.maxWatch
                    || (edited && Date().timeIntervalSince(lastChange) > Self.idleAfterEdit) {
                    break
                }
            }

            let found = TextProcessing.corrections(before: initial, after: latest, inserted: inserted)
            if !found.isEmpty {
                AppLog.write("found \(found.count) correction(s) in pasted text")
                self?.onCorrections?(found)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
