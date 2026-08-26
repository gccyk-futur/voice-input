# VoiceKit

[中文文档](README_zh.md)

VoiceKit is a macOS voice input assistant. Press a global hotkey, speak, and your words are transcribed in real time and automatically pasted at the cursor. Everything you say is kept locally — browse history, favorite it, save snapshots, and quick-insert it again anywhere.

**Download**: [GitHub Releases](https://github.com/gccyk-futur/voice-input/releases)

## Features

- **Global hotkey** (default `Cmd+Shift+V`) — summon the floating panel from any app
- **Real-time speech recognition** — see words appear as you speak, auto-paste when done
- **Four ASR engines** (pick in Settings, cloud engines are bring-your-own-key):
  - Apple Dictation (offline, free, built into macOS)
  - Alibaba Fun-ASR (cloud-based, high accuracy, auto punctuation)
  - iFLYTEK / Xunfei (cloud-based, streaming with dynamic correction)
  - Deepgram (cloud-based, low-latency streaming)
  - Unconfigured engines automatically fall back to Apple Dictation
- **Silence auto-stop** — automatically finishes after a configurable pause
- **AI polish** — send recognized text to an LLM (OpenAI / DeepSeek / Claude / Ollama) to convert spoken language into polished prose; built-in prompt preset library (bullet points, formal documents, etc.), one-click import
- **History center** — browse past transcriptions grouped by day, with search, favorites, and Markdown/JSON export
- **Snapshot library** — keep frequently used snippets permanently, with optional titles and editing
- **Quick-insert panel** (separate hotkey) — keyboard-first access to history, favorites, and snapshots; press Enter to insert into the current app
- **Usage stats** — local-only usage statistics, never leaves your device
- **Config resilience** — automatic backup on save, automatic recovery from corruption, never silently resets

## Languages

The interface follows the preferred language in macOS System Settings. VoiceKit currently includes:

- Simplified Chinese
- Traditional Chinese
- English
- Japanese
- Korean
- French
- German
- Spanish
- Brazilian Portuguese
- Italian

If the macOS language is not covered, the interface falls back to English. Russian is not included.

## Privacy

VoiceKit is a **pure client-side tool** — no backend servers, no data collection.

| Engine | Where your data goes |
|--------|---------------------|
| Apple Dictation | Processed **locally** by macOS, never leaves your device |
| Alibaba Fun-ASR | Audio sent directly to **your own Alibaba Cloud account** |
| iFLYTEK (Xunfei) | Audio sent directly to **your own iFLYTEK account** |
| Deepgram | Audio sent directly to **your own Deepgram account** |
| AI Polish | Text sent directly to **your configured AI provider**. With Ollama local models, data never leaves your machine |

- **No telemetry**: no analytics, no tracking, no phoning home
- **Local storage**: API keys and config stored in `~/Library/Application Support/VoiceMate/`
- **Privacy manifest**: `PrivacyInfo.xcprivacy` included for App Store compliance

## Requirements

- macOS 14+
- Xcode 16+ (dev build only)

## Dev Build

> Regular users should download the release DMG — no build required.

```bash
git clone https://github.com/gccyk-futur/voice-input.git
cd voice-input
xcodegen generate
open VoiceKit.xcodeproj
```

Configuration: copy `config.example.json` to `~/Library/Application Support/VoiceMate/config.json`, then fill in API keys in the Settings panel.

The maintainer uses 1Password CLI (`op read`) for signing certificates and secrets — see `scripts/`. Contributors can use Xcode automatic signing.

## Architecture

```
VoiceKit/
├── Sources/VoiceKit/
│   ├── ASR/              # Speech recognition engines (Apple Dictation / Alibaba Fun-ASR / iFLYTEK / Deepgram)
│   ├── LLM/              # LLM polish (OpenAI / DeepSeek / Claude / Ollama)
│   ├── Panel/            # Floating panel (NSPanel + vibrancy)
│   ├── Hotkey/           # Global hotkey (Carbon + NSEvent dual-engine)
│   ├── Paste/            # Paste back (Accessibility API + clipboard fallback)
│   ├── Config/           # Configuration persistence (3-layer defense: auto-backup / corruption recovery)
│   ├── History/          # History center (browse / favorites / export)
│   ├── Snapshot/         # Snapshot library + quick-insert panel
│   ├── Stats/            # Usage statistics
│   ├── Design/           # Design system (typography scale / shared controls)
│   ├── Support/          # User guide (bilingual, zh/en)
│   ├── Settings/         # Settings UI
│   ├── Coordinator/      # App coordinator + state machine
│   ├── Prompt/           # Prompt templates + built-in preset library
│   └── App/              # App entry point
├── docs/                 # Technical docs
├── skills/               # AI assistant skill (config guide & troubleshooting)
├── scripts/              # Build scripts (maintainer use)
├── project.yml           # xcodegen project definition
└── config.example.json   # Config template
```

## Tech Stack

Zero external dependencies. Swift 6 strict concurrency. Pure Apple frameworks.

## License

MIT
