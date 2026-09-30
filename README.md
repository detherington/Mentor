# Pepper

A Loom-style screen + webcam recording app for macOS, built to support guided software walkthroughs with smart zoom, webcam transitions, titles, and a presenter soundboard.

## What it does

- Menu-bar capture: screen (display, window or region) + webcam + mic + system audio into a `.pepper` sidecar bundle (raw tracks + event logs). Pause/resume, configurable global shortcuts (default ⌘⇧R record, ⌘⇧P pause).
- Post-capture render → composited MP4 with webcam overlay, smart zoom, cursor ripples/highlight, keystroke overlays and captions.
- Editor: live preview; trim + cuts, auto-trim silence; editable zoom + talking-head keyframes; webcam shape, position, transitions and background effects; title cards; audio mix + mic noise reduction; on-device transcription with editable captions (burned in or `.srt`); undo.
- Teleprompter: floating script window that stays out of the capture.
- Soundboard: audio cues fired by global hotkeys, mixed into the recording.
- Export to Orbis: OAuth sign-in (PKCE, loopback redirect), uploads the MP4 + transcript.
- Auto-update via Sparkle, with releases hosted on Orbis like Muesli.
- Signed with Developer ID, notarized, distributed as a `.dmg`.

## First-time setup

```
./scripts/bootstrap.sh
open Pepper.xcodeproj
```

The bootstrap script uses `xcodegen` from your PATH (e.g. `brew install xcodegen`), or builds it from source into `.local/bin` if there isn't one, then runs `xcodegen generate` to turn `project.yml` into the Xcode project. `project.yml` is the source of truth — `.xcodeproj` is gitignored; re-run `xcodegen generate` after adding folders or changing `project.yml`.

Signing is pinned to the Developer ID team (`8B29CDK832`) so TCC grants survive rebuilds; building elsewhere needs that cert or a local change to `project.yml`. In Xcode, press **⌘R**. First run will prompt for Camera, Microphone, Screen Recording, and Accessibility (the last one is for the event log + soundboard hotkeys).

## Distribution

Pepper ships the same way as Muesli: Orbis hosts the releases at `https://sbsorbis.com/download/pepper/`, and its Pepper download page (under Tools) reads the appcast and links the newest DMG.

| File | Used by |
| --- | --- |
| `appcast.xml` | Sparkle, daily (public; Sparkle can't sign in) and the download page |
| `Pepper-<version>.zip` | Sparkle's update download (public) |
| `Pepper<build>-<older build>.delta` | Sparkle's smaller updates from recent versions (public) |
| `Pepper-<version>.dmg` | the download page's button (the page swaps the zip's `.zip` for `.dmg`) |

Build numbers are UTC timestamps (`YYYYMMDDHHMM`), set by the release script: Sparkle orders updates by them and the download page compares them as text.

### First-time signing setup

1. Developer ID Application cert in your Keychain (team `8B29CDK832`).
2. Sparkle EdDSA key in the login Keychain (account `ed25519`), generated once with Sparkle's `generate_keys` (after a build it's at `build/SourcePackages/artifacts/sparkle/Sparkle/bin/`). The public key is `SUPublicEDKey` in `project.yml`; the release script refuses to sign with a key that doesn't match it. Never commit the private key.
3. A notarytool keychain profile with an app-specific password. The script uses `Picsy`; set `PEPPER_NOTARY_PROFILE` to use another name:
   ```
   xcrun notarytool store-credentials Picsy --apple-id dge@me.com --team-id 8B29CDK832
   ```

### Cutting a release

1. Bump `MARKETING_VERSION` in `project.yml`. Optionally add release notes as an HTML fragment at `release-notes/<version>.html`. Commit.
2. On `main`, run `scripts/release.sh`. It:
   - checks first: clean tree, version not released yet, feed URL, `main` up to date;
   - regenerates the project, does a clean Release build with a timestamp build number, and signs inside-out with hardened runtime;
   - notarizes and staples the app, zips it for Sparkle, builds the DMG from the stapled app, then notarizes and staples that;
   - runs Sparkle's `generate_appcast` over `dist/` (signs the zip, keeps earlier releases, writes deltas), after checking the Keychain key matches `SUPublicEDKey`;
   - copies exactly what to upload into `dist/upload-<version>/`, then tags `v<version>` and pushes.
3. Upload everything in `dist/upload-<version>/` to the Orbis Replit project's `client/public/download/pepper/`, replacing `appcast.xml`, then redeploy Orbis. Files only go live with a deploy.
4. Run `scripts/release.sh --verify`. It checks Orbis serves this version's appcast, zip and DMG with the right sizes. Orbis answers a missing file with its web page rather than a 404, so don't trust a browser check.

Installed copies pick the update up within a day, or immediately via Check for Updates. `scripts/release.sh --check` runs only the pre-build checks. Keep `dist/` between releases: it holds earlier zips for deltas and the appcast the next release builds on. The Sparkle package is pinned to an exact version in `project.yml`.

## Architecture

### Recording pipeline (Option A — post-capture render)

Live capture writes only the `.pepper` sidecar. No composited encoder during capture — keeps the media engine from running three concurrent HW encoders (visible jitter on M4-base otherwise). The composited `.mp4` is rendered post-capture by `FinalRenderer` using `AVAssetReader` + `AVAssetWriter` + the `LiveCompositor`.

```
~/Movies/Pepper/
├── Pepper_<timestamp>.mp4            ← composited final (shareable)
└── Pepper_<timestamp>.pepper/        ← sidecar
    ├── screen.mov                    ← H.264, 60fps
    ├── webcam.mov                    ← H.264, 30fps
    ├── mic.m4a                       ← AAC
    ├── system.m4a                    ← AAC (optional)
    ├── soundboard.m4a                ← AAC (only if cues fired)
    ├── soundboard-events.json        ← cue fire log
    ├── events.json                   ← clicks, keys, app focus
    ├── cursor.json                   ← 30 Hz cursor samples
    ├── talking-head.json             ← manual talking-head moments
    ├── zoom.json                     ← zoom keyframes (auto + edited)
    ├── edit-state.json               ← editor look: trim, cuts, webcam, title cards, styles
    ├── transcription.json            ← on-device transcript
    └── metadata.json                 ← source info, webcam layout
```

All tracks share one time origin (the first screen frame), and pauses are closed up by retiming samples, so the raw files line up without offsets.

### Module layout

| Folder | Responsibility |
| --- | --- |
| `Pepper/App/` | AppDelegate (wiring), RecordingFlowController (record/pause/stop state), EditorWindowManager, OpenURLRouter (Finder opens, single instance), CaptureDeviceMonitor, main menu, menu bar, debug log |
| `Pepper/Capture/` | CaptureCoordinator, PauseClock, ScreenCapture (SCStream), CameraCapture (AVCaptureSession), CaptureSource, CaptureContention |
| `Pepper/Recording/` | TrackWriter (raw video/audio tracks), EventRecorder, CursorSampler, bundle layout + metadata, TeleprompterController |
| `Pepper/Soundboard/` | SoundCue model, hotkey binding, AVAudioEngine wrapper, controller |
| `Pepper/Editor/` | RecordingProject, EditorComposition, LiveCompositor (custom AVVideoCompositing), OverlaySettings, EditorViewModel, EditState + SidecarStore, keyframe models, captions + transcription, silence/waveform analysis; `Inspector/` and `Timeline/` views |
| `Pepper/Rendering/` | FinalRenderer (AVAssetReader + AVAssetWriter pump), ExportQuality, SRTFormatter |
| `Pepper/Orbis/` | OAuth account + loopback server, Keychain, API client, export sheet/controller |
| `Pepper/UI/` | SwiftUI/AppKit windows (Settings, Soundboard, SourcePicker, RegionSelector, Countdown, RecordingBorder, WebcamPreview, Teleprompter) |
| `Pepper/Hotkeys/` | Carbon RegisterEventHotKey wrapper, configurable bindings |
| `Pepper/Settings/` | UserDefaults-backed prefs singleton |

### Custom compositor

`LiveCompositor` is an `AVVideoCompositing` that runs for both live editor preview and the `FinalRenderer` export pass. Each composition gets its own `State`, holding one `OverlaySettings` value (webcam layout, zoom/talking-head keyframes, title cards, cursor effects, captions, keystrokes); the editor swaps in a new value on each inspector change, the compositor reads a snapshot per frame. Export builds the same `OverlaySettings`, so preview and export can't drift.

Order in each frame: screen → cursor ripples → smart zoom → webcam (with fade + talking-head interpolation) → title cards → captions → keystroke overlays.

## Entitlements + permissions

- `Pepper.entitlements`: camera + microphone + audio-input, hardened runtime, **no** sandbox.
  - Sandbox is off intentionally — ScreenCaptureKit + Carbon global hotkeys + soundboard `NSEvent` monitors all work cleaner unsandboxed for DMG distribution.
- Required TCC prompts:
  - Camera, Microphone — for webcam + mic capture.
  - Screen Recording — for SCStream.
  - Accessibility — for the event log (clicks/keys) + global soundboard hotkeys.

## Tuning notes

- Raw H.264 tracks use High profile + `AVVideoAllowFrameReorderingKey: false` — minimal encoder latency during live capture, without Baseline's level ceiling (which rejects 4K+ on Apple Silicon).
- Export path uses High profile + frame-rate hints. No `AVAssetExportSession` — it picks heuristics that produce jittery output with mixed-rate sources.
- `AVAudioFile` can't encode AAC directly from non-interleaved float mixer taps, so the soundboard records to a temp `.caf` and transcodes to AAC on stop.
- Debug log at `~/Library/Logs/Pepper/pepper-debug.log` via `PepperDebug.log(...)`.

### Debug-build capture jitter

Expect visible frame drops in the screen track when recording from a **Debug** build, especially at retina sizes (≥3600×2338 @ 60fps). Debug is compiled `-Onone` with `@Observable` tracking and SwiftUI instrumentation fully inlined; the extra per-frame overhead eats into the HW H.264 encoder's time budget and `AVAssetWriter` starts dropping samples under back-pressure. Release (optimised, same code path) records cleanly.

**Always benchmark capture throughput from a Release build (`scripts/release.sh` output or an installed DMG) — never from the Xcode-run Debug binary.**
