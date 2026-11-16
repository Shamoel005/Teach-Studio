# Teach Studio

A native macOS app (SwiftUI + ScreenCaptureKit) for recording YouTube lectures on a Mac,
for example while writing on a digital pad. Think of it as a small, teaching-focused OBS.

## Features

- Screen recording of any display (1080p / 1440p / native, 30 or 60 fps)
- Audio: **system audio**, **microphone**, **both mixed into one track**, or none
- Microphone picker (built-in or external)
- **Webcam bubble** over the recording: circle or rounded square, adjustable size,
  solid or gradient border with adjustable thickness, mirror option, snap to any corner,
  draggable anywhere
- Camera picker, and external webcams are detected automatically when plugged in
- **Cursor / pen highlight** ring so students can follow what you point at
- **Pause / resume**
- 3-2-1 countdown, menu-bar controls, and global hotkeys
- Output is an `.mp4` (H.264 + AAC, single audio track) that you can upload to YouTube directly
- Named from your lecture title, saved to `~/Movies/Teaching Recordings` by default

## Hotkeys (work from any app)

| Keys | Action |
|------|--------|
| ⌃⌥R | Start / stop recording |
| ⌃⌥P | Pause / resume |
| ⌃⌥C | Show / hide webcam bubble |

## Requirements

- Apple Silicon Mac, macOS 15 or later
- Xcode or Command Line Tools (`xcode-select --install`)

## Build and run

```bash
git clone https://github.com/<your-username>/screen-recorder-mac.git
cd screen-recorder-mac
chmod +x build.sh
./build.sh
```

On first use, allow **Screen & System Audio Recording**, **Microphone** and **Camera**
in System Settings → Privacy & Security, then reopen the app.

## Project layout

```
.
├── build.sh
└── Sources/
    ├── App.swift         # app entry + menu-bar controls
    ├── AppModel.swift    # settings, state, recording flow, hotkeys
    ├── ContentView.swift # main window UI
    ├── Recorder.swift    # capture engine, pause/resume, YouTube-ready export
    ├── Camera.swift      # webcam bubble (circle + gradient border)
    └── Overlay.swift     # cursor highlight, countdown, global hotkeys
```

## Tips for teaching with a writing pad

- Record the display your writing app is on.
- While recording, the main window hides itself; control it from the menu-bar icon or hotkeys.
- The webcam bubble is a real window on your screen, so keep your writing area clear of it.
- When the recording stops, the app mixes mic + system audio and saves the final `.mp4`.

## Notes

- The app is ad-hoc signed, so macOS may ask you to re-grant permissions after a rebuild.
- If you change `com.example.teachstudio` in `build.sh`, permissions are tracked separately.
