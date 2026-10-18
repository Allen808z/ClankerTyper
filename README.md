# Clanker

A macOS dictation app. Hold a shortcut, speak, and your words are typed where your cursor is.
It began as a re-creation of HeyClicky's core loop (see [NOTES.md](NOTES.md)) and now borrows
dictation ideas from Wispr Flow. Not affiliated with either.

## Build and run

Requires macOS 14+ and the Swift 5.10+ toolchain (Command Line Tools is enough).

```bash
./scripts/build-app.sh
open build/Clanker.app
```

Allow Microphone, Speech Recognition and Accessibility when asked.

## Use

| Shortcut | What it does |
|---|---|
| Hold ⌃ Control + ⌥ Option | Dictate while held |
| Double-tap ⌃⌥ | Hands-free: keep dictating until you tap again |
| ⌃⌥V | Paste the last transcript again |

- A REC bubble above the pointer shows your words as you speak.
- Pauses are kept: each phrase ends with a full stop and the next starts with a capital.
- English and French can both be on; each phrase keeps the more confident language.
- Words are pasted where you were typing, even if focus moved while you talked, and always stay
  on the clipboard. Password fields are never typed into.
- Filler words are removed, spacing and capitals fit the text around the cursor, and sound is
  muted while you dictate. Each can be switched off in Settings.
- When you correct a pasted word that isn't everyday vocabulary (a name, a brand), Clanker
  learns it. Ordinary words and accidental one-letter deletions are not learned.
- Optional grammar cleanup through a local Ollama model.

The main window (menu bar icon → Open Clanker) has Home (stats and recent dictations),
History, Dictionary (your words, replacements and what was learned), Snippets and Settings.
Data is stored in `~/Library/Application Support/Clanker/store.json`; logs are in
`~/Library/Logs/Clanker/`.

An older ask mode (screenshots sent to Claude or Ollama, answers in a card) is still available
by turning off "Transcribe only" in Settings.

## Tests

```bash
./scripts/test.sh
```
