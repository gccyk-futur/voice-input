# VoiceKit

[中文文档](README_zh.md)

VoiceKit is a macOS voice input assistant. Press a global hotkey, speak, and your words are transcribed in real time and automatically pasted at the cursor.

**Download**: [GitHub Releases](https://github.com/gccyk-futur/voice-input/releases)

## Features

- **Global hotkey** (default `Cmd+Shift+V`) — summon the floating panel from any app
- **Real-time speech recognition** — see words appear as you speak, auto-paste when done
- **Dual ASR engines**:
  - Apple Dictation (offline, free, built into macOS)
  - Alibaba Fun-ASR (cloud-based, high accuracy, auto punctuation)
- **Silence auto-stop** — automatically finishes after a configurable pause
- **AI polish** — send recognized text to an LLM (OpenAI / DeepSeek / Claude / Ollama) to convert spoken language into polished prose
- **History** — browse all past transcriptions

## Privacy

VoiceKit is a **pure client-side tool** — no backend servers, no data collection.

| Engine | Where your data goes |
|--------|---------------------|
| Apple Dictation | Processed **locally** by macOS, never leaves your device |
| Alibaba Fun-ASR | Audio sent directly to **your own Alibaba Cloud account** |
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
│   ├── ASR/              # Speech recognition engines (Apple Dictation / Alibaba Fun-ASR)
│   ├── LLM/              # LLM polish (OpenAI / DeepSeek / Claude / Ollama)
│   ├── Panel/            # Floating panel (NSPanel + vibrancy)
│   ├── Hotkey/           # Global hotkey (Carbon + NSEvent dual-engine)
│   ├── Paste/            # Paste back (Accessibility API + clipboard fallback)
│   ├── Config/           # Configuration persistence
│   ├── History/          # History browser
│   ├── Settings/         # Settings UI
│   ├── Coordinator/      # App coordinator + state machine
│   ├── Prompt/           # Prompt templates
│   └── App/              # App entry point
├── docs/                 # Technical docs
├── scripts/              # Build scripts (maintainer use)
├── project.yml           # xcodegen project definition
└── config.example.json   # Config template
```

## Tech Stack

Zero external dependencies. Swift 6 strict concurrency. Pure Apple frameworks.

## License

MIT
