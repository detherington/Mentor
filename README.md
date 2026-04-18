# Mentor

A Loom-style screen + webcam recording app for macOS, built to support guided software walkthroughs with smart zoom, webcam transitions, titles, and a presenter soundboard.

## What it does

- Menu-bar capture: screen + webcam + mic + system audio into a `.mentor` sidecar bundle (raw multi-track + event log).
- Post-capture auto-render → composited MP4 with circular webcam overlay, smart zoom, and cursor ripples.
- Editor: live preview of layout changes, manual trim, auto-trim leading/trailing silence, editable zoom + talking-head keyframes, soundboard cue markers, audio-mix sliders, title cards, waveform strip.
- Soundboard: load audio cues, trigger globally via hotkey, mixed into the recording.
- Auto-update via Sparkle (appcast on GitHub Releases).
- Signed with Developer ID, notarized, distributed as a `.dmg`.

## First-time setup

```
./scripts/bootstrap.sh
.local/bin/xcodegen generate
open Mentor.xcodeproj
```

The bootstrap script builds XcodeGen locally from source into `.local/bin` (no Homebrew needed). `xcodegen generate` turns `project.yml` into the Xcode project (it's the source of truth — `.xcodeproj` is gitignored).

In Xcode, press **⌘R**. First run will prompt for Camera, Microphone, Screen Recording, and Accessibility (the last one is for the event log + soundboard hotkeys).

## Distribution

### First-time signing setup

1. Developer ID Application cert in your Keychain (team `8B29CDK832`).
2. Sparkle EdDSA keypair generated once via:
   ```
   ~/Library/Developer/Xcode/DerivedData/Mentor-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```
   The public key is in `project.yml` (`SUPublicEDKey`). The private key lives in your login keychain — never commits.
3. Notarytool keychain profile named `notary` with an app-specific password:
   ```
   xcrun notarytool store-credentials notary --apple-id dge@me.com --team-id 8B29CDK832
   ```

### Cutting a release

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in `project.yml`.
2. `./build-dmg.sh`
   - Clean build, signs with Developer ID, hardened runtime on.
   - Creates `Mentor.dmg`, signs + notarizes + staples.
   - Prints a `<sparkle:enclosure …>` block at the end.
3. Tag + push: `git tag v1.2.3 && git push --tags`
4. Create a GitHub Release `v1.2.3`; upload `Mentor.dmg` as the asset.
5. Paste the printed `<item>` block into `appcast.xml` at the top of `<channel>`.
6. Commit + push `appcast.xml`.

Sparkle checks the `https://raw.githubusercontent.com/detherington/Mentor/main/appcast.xml` URL daily; users get an in-app update prompt on the next check.

## Architecture

### Recording pipeline (Option A — post-capture render)

Live capture writes only the `.mentor` sidecar. No composited encoder during capture — keeps the media engine from running three concurrent HW encoders (visible jitter on M4-base otherwise). The composited `.mp4` is rendered post-capture by `FinalRenderer` using `AVAssetReader` + `AVAssetWriter` + the `LiveCompositor`.

```
~/Movies/Mentor/
├── Mentor_<timestamp>.mp4            ← composited final (shareable)
└── Mentor_<timestamp>.mentor/        ← sidecar
    ├── screen.mov                    ← H.264, 60fps
    ├── webcam.mov                    ← H.264, 30fps
    ├── mic.m4a                       ← AAC
    ├── system.m4a                    ← AAC (optional)
    ├── soundboard.m4a                ← AAC (only if cues fired)
    ├── soundboard-events.json        ← cue fire log
    ├── events.json                   ← clicks, keys, app focus
    ├── talking-head.json             ← manual talking-head moments
    ├── zoom.json                     ← zoom keyframes (auto + edited)
    └── metadata.json                 ← source info, webcam layout
```

### Module layout

| Folder | Responsibility |
| --- | --- |
| `Mentor/App/` | AppDelegate, menu bar, debug log |
| `Mentor/Capture/` | Coordinator, ScreenCapture (SCStream), CameraCapture (AVCaptureSession), CaptureSource |
| `Mentor/Recording/` | Raw track + audio writers, event recorder, bundle layout |
| `Mentor/Soundboard/` | SoundCue model, hotkey binding, AVAudioEngine wrapper, controller |
| `Mentor/Editor/` | RecordingProject, EditorComposition, LiveCompositor (custom AVVideoCompositing), EditorViewModel, keyframe models, WaveformSampler, SilenceAnalyzer, SourceCoordinateMapper |
| `Mentor/Rendering/` | FinalRenderer (AVAssetReader + AVAssetWriter pump), ExportQuality |
| `Mentor/UI/` | SwiftUI windows (SettingsWindow, SoundboardWindow, SourcePickerWindow, RegionSelectorWindow, CountdownOverlay, RecordingBorderWindow, WebcamPreviewWindow) |
| `Mentor/Hotkeys/` | Carbon RegisterEventHotKey wrapper |
| `Mentor/Settings/` | UserDefaults-backed prefs singleton |

### Custom compositor

`LiveCompositor` is an `AVVideoCompositing` that runs for both live editor preview and the `FinalRenderer` export pass. Its shared `State` singleton holds all overlay parameters (webcam layout, zoom/talking-head keyframes, title cards, cursor ripples, audio range); the editor writes to it on each inspector change, the compositor reads it per frame.

Order in each frame: screen → cursor ripples → smart zoom → webcam (with fade + talking-head interpolation) → title cards.

## Entitlements + permissions

- `Mentor.entitlements`: camera + microphone + audio-input, hardened runtime, **no** sandbox.
  - Sandbox is off intentionally — ScreenCaptureKit + Carbon global hotkeys + soundboard `NSEvent` monitors all work cleaner unsandboxed for DMG distribution.
- Required TCC prompts:
  - Camera, Microphone — for webcam + mic capture.
  - Screen Recording — for SCStream.
  - Accessibility — for the event log (clicks/keys) + global soundboard hotkeys.

## Tuning notes

- Raw H.264 tracks use Baseline profile + `AVVideoAllowFrameReorderingKey: false` — minimal encoder latency during live capture.
- Export path uses High profile + frame-rate hints. No `AVAssetExportSession` — it picks heuristics that produce jittery output with mixed-rate sources.
- `AVAudioFile` can't encode AAC directly from non-interleaved float mixer taps, so the soundboard records to a temp `.caf` and transcodes to AAC on stop.
- Debug log at `/tmp/mentor-debug.log` via `MentorDebug.log(...)`.

### Debug-build capture jitter

Expect visible frame drops in the screen track when recording from a **Debug** build, especially at retina sizes (≥3600×2338 @ 60fps). Debug is compiled `-Onone` with `@Observable` tracking and SwiftUI instrumentation fully inlined; the extra per-frame overhead eats into the HW H.264 encoder's time budget and `AVAssetWriter` starts dropping samples under back-pressure. Release (optimised, same code path) records cleanly.

**Always benchmark capture throughput from the `./build-dmg.sh` output or an installed DMG — never from the Xcode-run Debug binary.**
