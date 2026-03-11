# ScreenRecorder

A minimalist macOS menu-bar screen recorder. Click to start. Click to stop. Done.

## Features

- Records at full native resolution and screen refresh rate
- Optional microphone audio capture
- Saves as MP4 to a configurable output folder
- Lives in the menu bar — no Dock icon clutter

## Requirements

- macOS 15 or later

## Installation

1. Download `ScreenRecorder.zip` from the [latest release](https://github.com/corychainsman/screen-recorder/releases/latest)
2. Unzip and move `ScreenRecorder.app` to your Applications folder
3. Launch it — grant Screen Recording and Microphone permissions when prompted

## Usage

| Action | How |
|---|---|
| Start recording | Left-click the menu bar icon |
| Stop recording | Left-click the menu bar icon again |
| Open settings | Right-click → Settings... |
| Quit | Right-click → Quit ScreenRecorder |

Recordings are saved as MP4 files. When you stop, Finder opens to the output folder automatically.

## Building from Source

Requires Xcode command-line tools.

```bash
git clone https://github.com/corychainsman/screen-recorder.git
cd screen-recorder
swift build -c release
```

The binary will be at `.build/release/ScreenRecorder`.

## License

MIT
