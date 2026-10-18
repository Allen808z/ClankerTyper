# ClankerTyper

A macOS dictation app. Hold a shortcut, speak, and your words are typed where your cursor is.
It began as a re-creation of HeyClicky's core loop (see [NOTES.md](NOTES.md)) and now borrows
dictation ideas from Wispr Flow. Not affiliated with either.

## Build and run

Requires macOS 14+ and the Swift 5.10+ toolchain (Command Line Tools is enough).

```bash
./scripts/install.sh
```

This builds ClankerTyper, quits any running copy, installs it as `/Applications/ClankerTyper.app` and
opens it. Run it again after each change. `./scripts/build-app.sh` only builds `build/ClankerTyper.app`.

Allow Microphone, Speech Recognition and Accessibility when asked.

## Use

| Shortcut | What it does |
|---|---|
| Hold ⌃ Control + ⌥ Option | Dictate while held |
| Double-tap ⌃⌥ | Hands-free: keep dictating until you tap again |
| Hold ⌃⌥⇧ | Command mode: say what to do with highlighted text, or what to write |
| ⌃⌥Z | Undo the last dictation |
| ⌃⌥V | Paste the last transcript again |
| ⌃⌥G | Fix the grammar of highlighted text in any app |
| ⌃⌥E | Improve the writing of highlighted text in any app |

- A REC bubble above the pointer shows your words as you speak.
- Say "new line", "new paragraph" or "scratch that" (French: "nouvelle ligne", "à la ligne",
  "nouveau paragraphe", "efface ça") while dictating.
- With no text field to type into, dictation goes to a floating Scratchpad.
- ClankerTyper opens at login (Settings → App).
- Pauses are kept: each phrase ends with a full stop and the next starts with a capital.
- English and French can both be on; each phrase keeps the more confident language.
- Words are pasted where you were typing, even if focus moved while you talked, and always stay
  on the clipboard. Password fields are never typed into.
- Filler words are removed, spacing and capitals fit the text around the cursor, and sound is
  muted while you dictate. Each can be switched off in Settings.
- When you correct a pasted word that isn't everyday vocabulary (a name, a brand), ClankerTyper
  learns it. Ordinary words and accidental one-letter deletions are not learned.
- Before pasting, an on-device model corrects grammar so each phrase makes sense. If the model
  is unavailable, slow, or changes the meaning, your words are pasted as heard.
- Highlight text anywhere and press ⌃⌥G or ⌃⌥E: the selection is replaced (⌘Z undoes it).
  Or just highlight editable text, however you select it: Fix grammar and Improve writing buttons
  appear above it in apps that report their selection to macOS.
  More actions: make shorter, more formal, more friendly, translate English ↔ French, summarize,
  and your own saved instructions (main window → Actions).
  Check the prompts from Terminal with
  `/Applications/ClankerTyper.app/Contents/MacOS/ClankerTyper --rewrite grammar "text"`.

The main window (menu bar icon → Open ClankerTyper) has Home (stats and recent dictations),
History, Dictionary (your words, replacements and what was learned), Snippets and Settings.
Data is stored in `~/Library/Application Support/ClankerTyper/store.json`; logs are in
`~/Library/Logs/ClankerTyper/`.

An older ask mode (your question and screenshots sent to a vision model in Ollama on this Mac,
answers in a card) is still available by turning off "Transcribe only" in Settings.

## Privacy

Everything stays on the Mac:

- Speech is recognized on-device only. A language whose on-device model isn't installed is
  skipped rather than sent to Apple's servers (add it under System Settings → Keyboard → Dictation).
- Grammar correction and the writing tools use Apple's built-in on-device model (macOS 26 with
  Apple Intelligence), or Ollama on this Mac. Any Ollama address other than localhost is refused.
- History, dictionary and snippets live in `~/Library/Application Support/ClankerTyper/`.
- No accounts, analytics or cloud services. Logs record counts, not what you said.

## Requirements

- macOS 14 or later for dictation.
- For grammar correction and writing tools: macOS 26 with Apple Intelligence turned on (nothing to
  install), or [Ollama](https://ollama.com) with a model such as `qwen2.5vl:7b` (choose it in
  Settings → Writing tools). Without either, dictation still works and is pasted as heard.

## Tests

```bash
./scripts/test.sh
```
