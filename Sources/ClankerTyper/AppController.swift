import AppKit

/// Owns ClankerTyper's pieces and runs one recording at a time.
///
/// Dictation (transcribe-only mode): hold Control + Option and speak, or double-tap it for
/// hands-free and tap again to stop. The words are cleaned up, pasted where you were typing,
/// kept on the clipboard and saved to History. Corrections you make afterwards are learned.
///
/// Ask mode: the same recording is sent with screenshots to a vision model in Ollama on this Mac,
/// and the answer is shown. Nothing is ever sent off the Mac.
@MainActor
final class CompanionController {
    private enum Recording {
        case idle
        case holding(started: Date)
        case handsFree(started: Date)
    }

    /// A press shorter than this is a tap, not a hold.
    private let tapLength: TimeInterval = 0.3
    /// Two taps within this window start hands-free mode.
    private let doubleTapWindow: TimeInterval = 0.5

    private let overlay = CursorOverlay()
    private let card = ResponseCard()
    private let pushToTalk = PushToTalk()
    private let dictation = Dictation()
    private let speaker = Speaker()
    private let assistant = Assistant()
    private let muter = AudioMuter()
    private let watcher = CorrectionWatcher()
    private let selectionToolbar = SelectionToolbar()
    private var rewriting = false
    private let permissions = PermissionState()
    let store = ClankerTyperStore(directory: ClankerTyperStore.defaultDirectory())
    private lazy var hub = HubWindowController(store: store, permissions: permissions)
    private lazy var onboardingWindow = OnboardingWindowController(permissions: permissions)
    private var menu: StatusMenu?
    private var hotKeys: [HotKey] = []
    private var turnTask: Task<Void, Never>?

    private var recording: Recording = .idle
    private var lastTapEnded: Date?
    private var ignoreNextRelease = false
    private var focus = FocusSnapshot(app: nil, element: nil)

    func start() {
        let menu = StatusMenu()
        menu.onOpenHub = { [weak self] in self?.hub.show(.home) }
        menu.onAsk = { [weak self] in self?.openTypedAsk() }
        menu.onSettings = { [weak self] in self?.hub.show(.settings) }
        menu.onPermissions = { [weak self] in self?.onboardingWindow.show() }
        menu.onPasteLast = { [weak self] in self?.pasteLast() }
        menu.onFixGrammar = { [weak self] in self?.rewriteSelection(.grammar) }
        menu.onImproveWriting = { [weak self] in self?.rewriteSelection(.improve) }
        menu.onToggleCompanion = { [weak self] visible in
            AppSettings.showCompanion = visible
            self?.overlay.setVisible(visible)
            self?.refreshMenu()
        }
        menu.onToggleSpeech = { [weak self] on in
            AppSettings.speakReplies = on
            if !on { self?.speaker.stop() }
            self?.refreshMenu()
        }
        menu.onToggleLanguage = { [weak self] id, enabled in
            AppSettings.setLanguage(id, enabled: enabled)
            self?.refreshMenu()
        }
        menu.onToggleTranscribeOnly = { [weak self] on in
            AppSettings.transcribeOnly = on
            self?.applyMode()
        }
        self.menu = menu
        applyMode()

        overlay.start()
        overlay.setVisible(AppSettings.showCompanion)

        pushToTalk.onPress = { [weak self] in self?.shortcutPressed() }
        pushToTalk.onRelease = { [weak self] in self?.shortcutReleased() }
        pushToTalk.start()

        for shortcut in HotKey.Shortcut.allCases {
            let hotKey = HotKey(id: shortcut.rawValue, keyCode: shortcut.keyCode, modifiers: HotKey.controlOption) { [weak self] in
                switch shortcut {
                case .pasteLast: self?.pasteLast()
                case .fixGrammar: self?.rewriteSelection(.grammar)
                case .improveWriting: self?.rewriteSelection(.improve)
                }
            }
            if let hotKey {
                hotKeys.append(hotKey)
            } else {
                AppLog.write("could not register \(shortcut.label); another app may be using it")
            }
        }

        dictation.onPartial = { [weak self] text in
            self?.card.model.status = .listening(partial: text)
            self?.overlay.setLiveText(text)
        }
        card.model.onSubmit = { [weak self] text in self?.submit(text) }
        watcher.onCorrections = { [weak self] corrections in self?.learn(corrections) }
        selectionToolbar.onAction = { [weak self] style, target in self?.rewriteSelection(style, target: target) }
        selectionToolbar.isBusy = { [weak self] in
            guard let self else { return true }
            if case .idle = self.recording { return self.rewriting }
            return true
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissions.refresh() }
        }
        // Settings changed in the main window (languages, mode) are reflected in the menu.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMode() }
        }
    }

    func openHub(_ page: HubPage = .home) {
        hub.show(page)
    }

    func showStartWindow() {
        if AppSettings.onboardingDone {
            hub.show(.home)
        } else {
            onboardingWindow.show()
        }
    }

    // MARK: - Shortcut

    private func shortcutPressed() {
        AppLog.write("shortcut pressed")
        switch recording {
        case .handsFree:
            // In hands-free mode a tap ends the recording; its release is not a new gesture.
            ignoreNextRelease = true
            finishRecording()
        case .holding:
            break
        case .idle:
            beginRecording()
        }
    }

    private func shortcutReleased() {
        AppLog.write("shortcut released")
        if ignoreNextRelease {
            ignoreNextRelease = false
            return
        }
        guard case .holding(let started) = recording else { return }
        let held = Date().timeIntervalSince(started)
        guard held < tapLength else {
            finishRecording()
            return
        }

        if let last = lastTapEnded, Date().timeIntervalSince(last) < doubleTapWindow {
            // Second tap: keep listening until the next tap.
            lastTapEnded = nil
            recording = .handsFree(started: started)
            overlay.setRecordingLabel("HANDS-FREE")
            menu?.setStatus("Hands-free: tap ⌃⌥ to stop")
            AppLog.write("hands-free mode started")
        } else {
            // A single short tap: nothing to keep yet, but it may be the first of a double tap.
            lastTapEnded = Date()
            cancelRecording()
        }
    }

    private func beginRecording() {
        guard Permissions.isGranted(.microphone), Permissions.isGranted(.speech) else {
            report("Allow Microphone and Speech Recognition in Permissions to talk to ClankerTyper.")
            onboardingWindow.show()
            return
        }

        turnTask?.cancel()
        watcher.cancel()
        speaker.stop()
        overlay.cancelPointing()
        focus = FocusTracker.capture()
        if AppSettings.muteAudio { muter.begin() }
        // Load the local model now, so grammar correction is quick when the user stops talking.
        if AppSettings.aiCleanup { Rewriter().warmUp() }

        do {
            try dictation.start(languages: AppSettings.dictationLanguages, hints: store.recognitionHints)
        } catch {
            muter.end()
            AppLog.write("dictation failed: \(error.localizedDescription)")
            report(error.localizedDescription)
            return
        }

        recording = .holding(started: Date())
        overlay.setRecordingLabel("REC")
        overlay.setListening(true)
        if AppSettings.transcribeOnly {
            let skipped = dictation.skippedLanguages.map(Dictation.displayName)
            menu?.setStatus(skipped.isEmpty
                ? "Listening…"
                : "Listening… (\(skipped.joined(separator: ", ")) skipped: not installed on this Mac)")
        } else {
            card.model.userText = ""
            card.model.status = .listening(partial: "")
            card.show(focus: false)
        }
        AppLog.write("listening started in \(focus.appName ?? "unknown app")")
    }

    private func cancelRecording() {
        recording = .idle
        dictation.cancel()
        muter.end()
        overlay.setListening(false)
        overlay.setLiveText("")
        card.hide()
        menu?.setStatus(StatusMenu.readyHint)
    }

    private func finishRecording() {
        let started: Date
        switch recording {
        case .holding(let date), .handsFree(let date): started = date
        case .idle: return
        }
        recording = .idle
        overlay.setListening(false)
        let duration = Date().timeIntervalSince(started)
        let snapshot = focus

        Task { [weak self] in
            guard let self else { return }
            let raw = await self.dictation.stop()
            self.muter.end()
            self.overlay.setLiveText("")
            AppLog.write("transcript: \(raw.count) characters")

            guard !raw.isEmpty else {
                if self.dictation.heardNothing {
                    self.report("No sound from your microphone. Is it muted, or is the wrong one selected in System Settings → Sound?")
                } else {
                    self.report("I didn't catch that. Speak a little closer to the microphone.")
                }
                return
            }
            if AppSettings.transcribeOnly {
                await self.deliverDictation(raw, duration: duration, focus: snapshot)
            } else {
                self.submit(raw)
            }
        }
    }

    // MARK: - Dictation pipeline

    /// Cleans up the words, delivers them, saves them to History and starts watching for
    /// corrections.
    private func deliverDictation(_ raw: String, duration: TimeInterval, focus: FocusSnapshot) async {
        let languages = AppSettings.dictationLanguages
        var text = raw
        if AppSettings.removeFillers {
            text = TextProcessing.removeFillers(text, fillers: TextProcessing.fillerWords(for: languages))
        }
        if AppSettings.aiCleanup {
            text = await correctGrammar(text)
        }
        text = TextProcessing.applySnippets(text, store.snippets.map { ($0.trigger, $0.expansion) })
        text = TextProcessing.applyReplacements(text, store.replacements.map { ($0.from, $0.to) })

        var pasted = text
        if AppSettings.insertAtCursor, AppSettings.smartSpacing {
            pasted = TextProcessing.fitToContext(
                text,
                before: FocusTracker.textBeforeCursor(focus.element),
                isOrdinaryLowercaseWord: { SpellCheck.isOrdinaryWord($0, languages: languages) }
            )
        }

        let outcome: String
        if AppSettings.insertAtCursor {
            switch await TextInsertion.deliver(pasted, to: focus) {
            case .pasted:
                outcome = "pasted"
                menu?.setStatus("Pasted · also on clipboard")
                if AppSettings.learnCorrections, let element = focus.element {
                    watcher.watch(element: element, inserted: pasted.trimmingCharacters(in: .whitespaces))
                }
            case .notPasted:
                outcome = "copied"
                report("Couldn't paste here. It's on your clipboard: press ⌘V.")
            case .secureField:
                outcome = "copied"
                report("That's a password field, so nothing was typed. It's on your clipboard.")
            case .notAllowed:
                outcome = "copied"
                report("It's on your clipboard. Allow ClankerTyper under Accessibility to paste it for you.")
            }
        } else {
            TextInsertion.putOnClipboard(text)
            outcome = "copied"
            menu?.setStatus("Copied to clipboard")
        }

        store.addHistory(HistoryItem(
            date: Date(),
            rawText: raw,
            text: text,
            appName: focus.appName,
            duration: duration,
            words: TextProcessing.wordCount(text),
            outcome: outcome
        ))
    }

    /// Makes each dictated phrase a correct, sensible sentence with the local model before it is
    /// pasted. The original is kept when the model is unavailable, slow, or goes off track.
    private func correctGrammar(_ text: String) async -> String {
        do {
            return try await Rewriter().rewrite(text, style: .dictation, timeout: 20)
        } catch {
            AppLog.write("grammar correction skipped: \(error.localizedDescription)")
            return text
        }
    }

    /// Control + Option + G or E, or the menu: fixes or improves the highlighted text in the app
    /// in front, and replaces it.
    /// - Parameter given: where the selection is, when the selection toolbar already knows.
    private func rewriteSelection(_ style: Rewriter.Style, target given: FocusSnapshot? = nil) {
        // Holding Control + Option to press the letter starts a recording; it was never meant as one.
        if case .holding = recording {
            cancelRecording()
            ignoreNextRelease = true
        }
        guard !rewriting else { return }
        selectionToolbar.hide()
        let target = given ?? FocusTracker.capture()
        guard !FocusTracker.isSecure(target.element) else {
            report("That's a password field, so it was left alone.")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await KeyStroke.waitForModifiersReleased()
            guard let selected = await SelectionReader.read(from: target),
                  !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.report("Highlight some text first, then press ⌃⌥G to fix grammar or ⌃⌥E to improve it.")
                return
            }
            self.overlay.showBusy("\(style.label)…")
            self.menu?.setStatus("\(style.label)…")
            self.rewriting = true
            defer {
                self.overlay.showBusy(nil)
                self.rewriting = false
            }

            let result: String
            do {
                result = try await Rewriter().rewrite(selected, style: style, timeout: 60)
            } catch {
                AppLog.write("\(style.label) failed: \(error.localizedDescription)")
                self.report(error.localizedDescription)
                return
            }
            guard result != selected else {
                self.menu?.setStatus("Already correct, nothing changed")
                return
            }
            switch await TextInsertion.deliver(result, to: target) {
            case .pasted:
                self.menu?.setStatus("Replaced · ⌘Z in the app undoes it")
            default:
                self.report("The new text is on your clipboard: press ⌘V to replace your selection.")
            }
            AppLog.write("\(style.label): \(TextProcessing.wordCount(selected)) words in, \(TextProcessing.wordCount(result)) out")
        }
    }

    private func learn(_ corrections: [TextProcessing.Correction]) {
        let languages = AppSettings.dictationLanguages
        var learned: [String] = []
        for correction in corrections
        where TextProcessing.shouldLearn(correction, isOrdinaryWord: { SpellCheck.isOrdinaryWord($0, languages: languages) }) {
            if store.learn(correction) {
                learned.append(correction.corrected)
                AppLog.write("learned a correction (\(correction.corrected.count) characters)")
            }
        }
        if !learned.isEmpty {
            menu?.setStatus("Learned: \(learned.joined(separator: ", "))")
        }
    }

    /// Control + Option + V, or the menu: pastes the last dictation again.
    private func pasteLast() {
        // Holding Control + Option to press V starts a recording; it was never meant as one.
        if case .holding = recording {
            cancelRecording()
            ignoreNextRelease = true
        }
        guard let last = store.lastTranscript else {
            menu?.setStatus("Nothing dictated yet")
            return
        }
        let target = FocusTracker.capture()
        Task { [weak self] in
            switch await TextInsertion.deliver(last, to: target) {
            case .pasted: self?.menu?.setStatus("Pasted last transcript")
            default: self?.report("Last transcript is on your clipboard: press ⌘V.")
            }
        }
    }

    /// Shows a message in the card (ask mode) or on the menu's top line (transcribe-only mode).
    private func report(_ message: String) {
        if AppSettings.transcribeOnly {
            menu?.setStatus(message)
        } else {
            card.model.userText = ""
            card.model.status = .error(message)
            card.show(focus: false)
        }
    }

    // MARK: - Ask mode

    private func openTypedAsk() {
        if !card.isShown {
            card.model.userText = ""
            card.model.status = .idle
        }
        card.show(focus: true)
    }

    private func submit(_ request: String) {
        turnTask?.cancel()
        card.model.userText = request
        card.model.status = .thinking
        card.show(focus: false)
        turnTask = Task { [weak self] in
            await self?.runTurn(request)
        }
    }

    private func runTurn(_ request: String) async {
        do {
            let captured = try await ScreenCapture.captureScreens()
            guard !Task.isCancelled else { return }
            let reply = try await assistant.reply(
                to: request,
                screens: captured.map(\.encoded),
                host: URL(string: AppSettings.ollamaHost) ?? OllamaClient.defaultHost,
                model: AppSettings.ollamaModel
            )
            guard !Task.isCancelled else { return }

            let spoken = reply.spokenText.isEmpty ? "Done." : reply.spokenText
            card.model.status = .reply(spoken)
            if let target = reply.target {
                point(at: target, in: captured)
            }
            if AppSettings.speakReplies {
                speaker.speak(spoken)
            }
        } catch {
            // A superseded turn is cancelled on purpose; its error must not overwrite the new state.
            guard !Task.isCancelled else { return }
            card.model.status = .error(error.localizedDescription)
        }
    }

    private func point(at target: PointTarget, in captured: [ScreenCapture.CapturedScreen]) {
        let index = (target.screenIndex ?? 1) - 1
        guard captured.indices.contains(index) else { return }
        let screen = captured[index]
        let description = screen.encoded.description
        let point = PointMapping.screenPoint(
            x: target.x,
            y: target.y,
            imageSize: CGSize(width: description.pixelWidth, height: description.pixelHeight),
            displayFrame: screen.appKitFrame
        )
        overlay.point(at: point, label: target.label)
    }

    /// Applies the transcribe-only switch to the card and menu.
    private func applyMode() {
        card.model.transcribeOnly = AppSettings.transcribeOnly
        if AppSettings.selectionToolbar {
            selectionToolbar.start()
        } else if selectionToolbar.isRunning {
            selectionToolbar.stop()
        }
        refreshMenu()
    }

    private func refreshMenu() {
        menu?.refresh(
            showCompanion: AppSettings.showCompanion,
            speakReplies: AppSettings.speakReplies,
            transcribeOnly: AppSettings.transcribeOnly
        )
    }
}
