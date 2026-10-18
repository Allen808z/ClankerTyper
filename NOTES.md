# Clanker: re-creation notes (reference app: HeyClicky)

Reference: `/Applications/HeyClicky.app` (bundle id `com.humansongs.clicky`, version 1.0.53 build 64,
Developer ID signed). The original was inspected statically only: plists, `strings` and `otool`
output from the arm64 slice, asset catalog listing, and the bundled resources. The binary was never
run, and nothing was copied from it.

## Observed (read from the bundle)

| Item | Evidence |
|---|---|
| Menu bar / agent app with no Dock icon | `LSUIElement = true` |
| Push-to-talk on Control + Option, listens only while held | Binary copy: "hold control and option to just talk to me"; "HeyClicky only listens while you hold the shortcut." |
| Screen capture only on an explicit help request | Strings: "HeyClicky only captures pixels during an explicit help request." |
| Blue companion that flies to on-screen targets | Symbols `BlueCursorView`, `guidedClickTarget`; prompt grammar `[POINT:x,y:label]`, `[TARGET:…]`, `[HOVER:…]`, `[HIGHLIGHT:…]`, `[SHAPE:…]` |
| Speech-to-text | `AppleSpeechTranscriptionSession`, `DictationDeepgramTranscriber`, `api.deepgram.com`, `/v2/dictation/deepgram-token` |
| Realtime voice | `RealtimeVoiceClient`, `gpt-realtime-2.1`, worker route `/agent/realtime/session` |
| Model access via a HeyClicky backend | `WorkerBaseURL` / `CodexWorkerBaseURL` = `https://api.heyclicky.com`; Supabase auth; PostHog and Sentry |
| Anthropic direct URL present | `AnthropicMessagesURL` in Info.plist; `ClaudeAPIC` class |
| Notch-docked surfaces, response cards, place and stock widgets | Symbols `NotchRootView`, `ResponseCard…`, `PlaceDetailView`, `StockWidget` |
| Agent "Clickys", Home window, integrations, routines, skills | Symbols `HomeSpace…`, `Clicky…`, `ClickyIntegrationSkills/`, `ClickyBundledSkills/`, user-facing copy |
| Bundled Codex CLI runtime 0.152.1 | `Resources/CodexRuntime/` |
| Computer use via embedded `cua-driver` (third-party, trycua) | `Helpers/cua-driver`, `ClickyBundledSkills/cua-driver` |
| Onboarding, permissions copy | Info.plist usage strings; strings "Not now", "Continue", "Allow" |
| Icon look | `AppIcon.icns`: blue sky with clouds, white zigzag glyph (viewed, not copied) |

Usage strings from Info.plist used as reference wording: microphone, speech recognition, screen recording, and "HeyClicky reads the document you're viewing".

## Inferred (not verified against the original's behaviour)

- The exact pointing coordinate convention. The prompt text in the binary shows pixel coordinates in
  screenshot space, and this re-creation assumes top-left origin with the image size given in the prompt.
- Whether the original also treats a short tap as cancelled (this re-creation drops holds under 0.25 s).
- The blue colour value and the card layout are approximations, not measured from the original.
- The model default (`claude-sonnet-5-5`) follows the Claude 5 family IDs in the environment notes.

## Re-created (this project)

- Menu bar item with: hint, Ask by typing, show-companion and speak toggles, Permissions, Settings, Quit.
- Hold Control + Option (global flags monitor) → Apple Speech recognition (on-device when offered) → screenshot of up to three displays (ScreenCaptureKit, HeyClicky's own windows excluded) → Anthropic Messages API → response card + optional speech.
- `[POINT:x,y:label(:screenN)]` / `[POINT:none]` parsing; the companion flies there along an arc, holds 4 s with a label, then returns to follow the mouse.
- Typed questions in the card with Esc to close. Requests time out after 90 s.
- Settings: API key in the Keychain (or `ANTHROPIC_API_KEY`), model picker, speak toggle, companion toggle, live permission status.
- First-run permission window.

## Out of scope (not re-created)

Clicky agents / Codex runtime, Home window and notch UI, integrations (Composio, Gmail, Linear, and others), routines and scheduling, skill library and publishing, computer use / cua-driver, Deepgram and OpenAI realtime voice, place and stock widgets, morning brief, referrals, billing and paywall, Supabase accounts, Sparkle auto-update, PostHog and Sentry telemetry, the onboarding tutorial videos.

## Assets

- No original artwork, audio, video, fonts, or logos were copied. The app icon is drawn by `scripts/make-icon.swift`.
- The bundled `.wav` and `.mp3` cues, the `.mp4` onboarding videos, and the integration logos were not used.
- The Hermes Agent skill files in the original (MIT licence, noted in its ATTRIBUTION.md) were not copied.

## Verification

| Check | Result |
|---|---|
| `./scripts/test.sh` (16 Swift Testing tests: parser, mapping, motion, API request/response) | Passed |
| `./scripts/build-app.sh` produces a signed bundle; `plutil -lint` on Info.plist | Passed |
| Launch of the built app | Crashed on first build (AppKit `NSWindow` initializer re-dispatch trap in `OverlayWindow`). Fixed by using the four-argument initializer. Relaunch stable. |
| Screenshot of the running app | Onboarding window renders with four permission rows. Companion arrow visible at the cursor. |

Not verified (blocked on permissions or a key in this session):
- Live Anthropic request and reply: no API key is set in this environment, so nothing was sent.
- Push-to-talk capture, speech recognition, screenshot capture, speech output and pointing end to end: they need the user to grant the four permissions to the built app.
- Behaviour on Intel Macs; the build is arm64 only.
- Multi-display pointing.
