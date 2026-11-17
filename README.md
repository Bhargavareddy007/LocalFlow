# LocalFlow

[![Download](https://img.shields.io/github/v/release/Bhargavareddy007/LocalFlow?label=Download&color=2ea44f)](https://github.com/Bhargavareddy007/LocalFlow/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Bhargavareddy007/LocalFlow/total?label=downloads)](https://github.com/Bhargavareddy007/LocalFlow/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 26+ · Apple silicon](https://img.shields.io/badge/macOS%2026%2B-Apple%20silicon-lightgrey)

Voice typing for macOS that never leaves your Mac. Hold a key, talk, let go: the words appear wherever your cursor is. An offline alternative to Wispr Flow.

<p align="center"><img src="docs/demo.gif" width="760" alt="Holding fn, speaking a sentence while the pill shows a live waveform, releasing, and the sentence appearing in a TextEdit document"></p>

- **Private.** Audio goes from the microphone to a speech model running on your Mac's GPU. No account, no cloud, no network calls. Turn Wi-Fi off and it keeps working.
- **Fast.** The default engine transcribes 8 seconds of speech in under 100 ms on an M-series Mac.
- **Works everywhere.** Any app with a text cursor: Mail, Slack, browsers, editors, terminals.

## Install (no Terminal needed)

1. Download `LocalFlow.zip` from the [latest release](../../releases/latest) and unzip it.
2. Drag **LocalFlow** into Applications and open it. The app is signed and notarized by Apple, so it opens with a double-click.
3. A setup window downloads the speech model (669 MB, one time) and asks for two permissions: Microphone, and Accessibility (so it can see the hotkey and type into other apps).
4. Hold **fn**, talk, release.

Requirements: a Mac with an Apple chip (M1 or newer), macOS 26 (Tahoe) or newer, internet once for the model download.

## Features

<img src="docs/menu.png" width="400" align="right" alt="The LocalFlow menu: dictation key, engine, language, polish wording, filler-word removal, smart spacing, hands-free mode, sounds, last dictation, setup and permissions">

- Hold fn to dictate; double-tap fn for hands-free mode, tap once to finish. Other keys selectable in the menu.
- Two local engines. **Parakeet** is the default: very fast, and it handles English and 24 European languages (Greek, German, French, Spanish, and more) without you picking one. **Whisper large-v3-turbo** covers about 100 languages for everything Parakeet doesn't, including Chinese, Hindi, Arabic, Japanese, Korean and Turkish.
- Optional **polish wording**: a small local language model (1.1 GB download) that fixes grammar and removes stumbles before typing. Off until you enable it in the menu.
- Filler-word removal, "new line" / "new paragraph" commands, a personal dictionary for names it mishears, smart spacing, clipboard preserved.
- Floating waveform while you speak, menu bar icon, your last dictation in the menu for 2 minutes (click to copy), launch at login.

<br clear="right">

## Privacy

Everything stays on the machine. The only network requests the app ever makes are the one-time model downloads from Hugging Face (huggingface.co, which redirects to its CDN on a *.hf.co host), pinned to an exact file version and verified against a pinned checksum. The app only ever loads those three files and checks each one's checksum every time it loads it: the speech models load from the very bytes that were checked, and the optional polish model through the same open file that was checked. To type into other apps, LocalFlow briefly puts the text on the clipboard and then puts your previous clipboard back; the text is marked local-only and private, so Universal Clipboard and clipboard managers skip it. It never types into password fields. No history is kept: only your last dictation stays in memory for 2 minutes, so you can copy it again from the menu if a paste didn't land, and nothing is written to disk. Text left on the clipboard instead of pasted (because focus moved, or copied from the menu) is cleared after the same 2 minutes, unless you've copied something else since. The log never contains dictated text unless you switch that on for troubleshooting, in the menu: the menu bar icon turns orange while it's on, it turns itself off when the app quits, and it wipes the log when turned off.

Files live in `~/Library/Application Support/LocalFlow/` (models, personal dictionary) and `~/Library/Logs/LocalFlow.log`.

## Build from source

Requires Xcode 16+ and Homebrew.

```
brew install whisper.cpp llama.cpp
./build.sh            # builds build/LocalFlow.app with the engine libraries bundled inside
./build.sh install    # also copies it to /Applications and launches it
./build.sh notarize   # signs with a Developer ID certificate, notarizes, staples, zips (needs an Apple Developer account)
```

Engine test without a microphone:

```
"build/LocalFlow.app/Contents/MacOS/LocalFlow" --transcribe clip.wav parakeet
"build/LocalFlow.app/Contents/MacOS/LocalFlow" --transcribe clip.wav whisper te
"build/LocalFlow.app/Contents/MacOS/LocalFlow" --polish "um so I think we should uh move the meeting"
```

Debug builds (`swift build`) also honour two troubleshooting preferences that release builds ignore: `saveRecordings` (keeps the last 30 recordings as WAV files) and `signalToggle` (`kill -USR1` toggles hands-free dictation).

## How it works

A CGEvent tap watches the hotkey. AVAudioEngine captures the microphone and resamples to 16 kHz. The audio goes to Parakeet or Whisper through the whisper.cpp libraries, Metal-accelerated. Rule-based cleanup runs, then optionally the Qwen 2.5 rewrite through llama.cpp. The result is placed on the clipboard, pasted with a synthetic Cmd+V into the app you were in when you started talking, and your previous clipboard is restored.

Built with [Claude Code](https://claude.com/claude-code). Third-party components and model licenses: see [THIRD_PARTY.md](THIRD_PARTY.md).

## License

MIT. See [LICENSE](LICENSE).
