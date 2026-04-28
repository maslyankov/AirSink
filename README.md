# AirSink

> A small macOS app that mirrors iPhone and iPad screens into resizable windows over AirPlay — without the full-screen takeover the built-in macOS AirPlay Receiver forces.

Built for developers, designers, and marketing teams who need to *see* their iOS device on their Mac while still using the Mac.

![Main window](docs/screenshots/main-window.png)
![Mirroring](docs/screenshots/mirroring.png)

## Features

- **Windowed mirroring** — each device gets its own resizable, draggable, minimisable NSWindow. Use your Mac normally while it's open.
- **Multiple devices, simultaneously** — slots are spawned on demand. Mirror an iPhone and an iPad at the same time, each into its own window.
- **Native rendering** — frames are decoded with VideoToolbox and drawn through `AVSampleBufferDisplayLayer` for sharp Retina output.
- **Coexists with macOS's built-in AirPlay Receiver** — runs on a separate port; both show up in the iOS picker.
- **No dock clutter** — receiver subprocesses are demoted to accessory apps; the only icon you see is AirSink itself.

## Install

### Homebrew (recommended)

```sh
brew tap maslyankov/airsink
brew install --cask airsink
```

### DMG

Download the latest `AirSink-x.y.z.dmg` from [Releases](https://github.com/maslyankov/AirSink/releases/latest), drag `AirSink.app` into `/Applications`, then on first launch right-click → Open (the binary is signed but not Apple-notarised on free tier yet).

### From source

```sh
brew install cmake pkg-config gstreamer libplist openssl@3
git clone https://github.com/maslyankov/AirSink.git
cd AirSink
./scripts/build-app.sh
open build/AirSink.app
```

## Use

1. Launch AirSink. It spawns a single receiver slot waiting for a device.
2. (Optional) In **System Settings → General → AirDrop & Handoff**, turn off **AirPlay Receiver**, or just leave AirSink on its non-conflicting default ports (7100+).
3. On your iPhone or iPad: **Control Center → Screen Mirroring → pick `<your-mac> (AirSink 1)`**.
4. A window pops open with your device's screen. Mirror a second device — it lands on Slot 2 in its own window. Repeat.

Click **Disconnect** on a device row to drop just that one (the slot restarts ready for the next device). Click **Stop receivers** to stop everything.

## Architecture

```
iPhone / iPad
    │  AirPlay (FairPlay-encrypted H.264 / H.265)
    ▼
uxplay subprocess (1 per slot, on its own port)
    │  decrypts, exposes raw NALUs over a Unix socket (-tap)
    ▼
AirSink.app
    │  socket → NALUDepacketizer → CMVideoFormatDescription
    ▼
AVSampleBufferDisplayLayer (one NSWindow per device)
```

The receiver subprocess is a patched [UxPlay](https://github.com/FDH2/UxPlay) — see `vendor/UxPlay/lib/frame_tap.{c,h}` for the tap module that streams pre-decode NALUs to the host app instead of going through GStreamer's own renderer. The host then decodes natively with VideoToolbox.

## Roadmap

- [x] Multi-device with dynamic slot allocation
- [x] Per-device resizable windows
- [x] Native VideoToolbox decode
- [x] System AirPlay Receiver coexistence
- [x] Subprocess hidden from Dock
- [ ] Recording (export each device window to MP4 via `AVAssetWriter`)
- [ ] Snapshot / hotkeys per window
- [ ] CMTimebase pacing for smoother bursts
- [ ] USB capture path (`AVCaptureDevice`) as an MAS-eligible alternative
- [ ] Apple-notarised release builds

## Project layout

```
AirSink/
├── Sources/                  Swift app (SwiftUI + AppKit)
├── vendor/UxPlay/            Vendored UxPlay with our frame-tap patch
│   └── lib/frame_tap.{c,h}   Adds -tap <socket> flag for fan-out
├── scripts/
│   ├── build-app.sh          swiftc + Info.plist + codesign + bundle uxplay
│   ├── make-dmg.sh           Pack the .app into a DMG
│   └── capture-screenshots.sh  Helper for README screenshots
├── .github/workflows/        CI (PR builds) and Release (tag → DMG)
├── VERSION                   Single source of truth for the marketing version
└── docs/screenshots/         README assets
```

## Contributing

Issues and PRs welcome. For UI changes, please include before/after screenshots. For uxplay patches, keep them minimal and ideally upstreamable.

## License

- AirSink (everything outside `vendor/`): **MIT** — see [LICENSE](LICENSE).
- The patches under `vendor/UxPlay/`: **GPL-3.0**, inherited from UxPlay.

## Acknowledgements

- [UxPlay](https://github.com/FDH2/UxPlay) for the AirPlay receiver implementation
- [GStreamer](https://gstreamer.freedesktop.org/) for the media pipeline used by uxplay
