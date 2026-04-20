# CLAUDE.md — Mentor

Guidance for Claude when working in this repo. Keep this file lean — it's
read at the start of every session.

## What this is

Native macOS menu-bar app: Loom-style screen + webcam + mic + system-audio
recording, with a built-in editor (smart zoom, webcam overlays, title cards,
teleprompter, soundboard). Swift + AppKit + SwiftUI, ScreenCaptureKit for
screen, AVFoundation for camera/mic, custom `AVVideoCompositing` for
compositing, Sparkle for auto-update.

Distribution: Developer-ID-signed, notarized DMG hosted on GitHub Releases.
Auto-update via Sparkle appcast at `appcast.xml` on `main`. LSUIElement app
(menu-bar only by default; promotes to `.regular` activation when an editor
window opens, demotes back on last-editor close).

Single-maintainer project; ship cadence is "whenever a feature's ready."
Version is `CFBundleShortVersionString` in `project.yml` — currently 1.0.8.

## Source of truth is `project.yml`

**The `.xcodeproj` is gitignored and regenerated from `project.yml` via
XcodeGen on every release build.** Do not edit `project.pbxproj` expecting
changes to persist — they'll be wiped by `build-dmg.sh`'s xcodegen step.
If you add a new Swift file, it should be picked up automatically by the
`sources: [path: Mentor]` rule; you only need to touch `project.yml` to
add a new top-level folder, framework dep, or Info.plist key.

That said, when iterating locally during a session, the current pbxproj
may have been edited by hand (e.g. to add a file that didn't exist yet)
— rebuilding with `xcodebuild` uses whatever's on disk. A regeneration
only happens during `./build-dmg.sh`.

## Build / run / ship

| Action | Command |
| --- | --- |
| Debug build | `xcodebuild -project Mentor.xcodeproj -scheme Mentor -configuration Debug -destination 'platform=macOS' build` |
| Launch dev build | `pkill -x Mentor; open <DerivedData>/Build/Products/Debug/Mentor.app` |
| Regenerate xcodeproj | `.local/bin/xcodegen generate` |
| Ship a release | `./build-dmg.sh` (see "Release workflow" below) |

There are no unit tests in this repo — validation is manual ("smoke-test a
recording, confirm the .mp4 renders and the editor opens it"). Don't
invent test infrastructure unless asked.

### Debug builds drop frames

Debug builds visibly stutter on the screen track at retina resolutions
(≥3600×2338 @ 60fps). Root cause: `-Onone` + SwiftUI `@Observable`
tracking eats enough per-frame time that the HW H.264 encoder misses its
budget and `AVAssetWriter` starts dropping samples. **Never benchmark
capture throughput from a Debug build.** Release builds (what ships in
the DMG) record cleanly.

## Architecture

### Recording pipeline — post-capture render (Option A)

Live capture writes **only** the `.mentor` sidecar bundle (raw tracks +
JSON event logs). The composited MP4 is rendered post-capture by
`FinalRenderer` using `AVAssetReader` + `AVAssetWriter` + `LiveCompositor`.
Rationale: three concurrent HW encoders (screen, webcam, composited) causes
visible jitter on M4-base; one live encoder per raw track is fine.

```
~/Movies/Mentor/
├── Mentor_<timestamp>.mp4            composited final (shareable)
└── Mentor_<timestamp>.mentor/        sidecar bundle (editable)
    ├── screen.mov                    H.264 Baseline, 60fps, frame-reordering off
    ├── webcam.mov                    H.264, 30fps
    ├── mic.m4a                       AAC
    ├── system.m4a                    AAC (optional)
    ├── soundboard.m4a                AAC (only if cues fired)
    ├── soundboard-events.json        cue fire log
    ├── events.json                   clicks, keys, app focus, modifiers
    ├── cursor.json                   30 Hz mouse-location samples
    ├── talking-head.json             manual talking-head moments
    ├── zoom.json                     zoom keyframes (auto + edited)
    ├── title-cards.json              title card layout
    ├── teleprompter.json             script + settings
    ├── transcription.json            on-device SpeechAnalyzer output
    └── metadata.json                 source info, webcam layout, dims
```

### CaptureCoordinator is the central hub

`Mentor/Capture/CaptureCoordinator.swift` owns: ScreenCapture (SCStream),
CameraCapture (AVCaptureSession), all writers, event/cursor recorders,
soundboard reference, pause state. Sample handlers live on the
`ScreenCaptureDelegate` / `CameraCaptureDelegate` extensions and are the
hot path — any work done here has to be lock-safe and fast.

Three locks, never hold more than one at a time:
- `pipelineLock` — mutates `screenRawWriter` / `webcamRawWriter` / etc.
- `pauseLock` — `_isPaused`, `_pauseStart`, `_cumulativePauseOffset`
- `stateLock` — `_isRecording`
- `coordStatsLock` — telemetry counters
- `observerLock` — `_cameraFrameObserver` closure
- `micTapLock` — `_micSampleSink` closure

The sample-handler pattern is: grab a snapshot under the lock, release,
then do the actual work. See `pauseStateForSample()` for the canonical
form.

### Pause/resume retiming

Pause/resume uses `CMSampleBufferCreateCopyWithNewTiming` via
`SampleBufferRetiming.swift`'s `CMSampleBuffer.retimed(by:)` extension.
`_cumulativePauseOffset` tracks wall-clock time spent paused (via
`CMClockGetHostTimeClock`); every post-pause A/V sample has its PTS
shifted back by that offset so the encoded track has no freeze-frame
gap. `EventRecorder` + `CursorSampler` do the same in TimeInterval space
so their JSON logs stay aligned with retimed video.

### Custom compositor

`Mentor/Editor/LiveCompositor.swift` is an `AVVideoCompositing`
implementation that drives **both** the live editor preview and the
`FinalRenderer` export pass. A shared `State` singleton holds all overlay
parameters (webcam layout, zoom keyframes, talking-head keyframes, title
cards, cursor ripples, audio range). The editor writes to it on inspector
changes; the compositor reads per frame.

Per-frame order: screen → cursor ripples → smart zoom → webcam (with
fade + talking-head interpolation) → title cards → keystroke overlays.

**Watch out:** the singleton is a race hazard. The editor and
`FinalRenderer`'s background render can both try to write to it
simultaneously. `FinalRenderer.isRendering` + `renderLock` guards
against this — the editor's `applyLayout` checks **both**
`isExporting` and `FinalRenderer.isRendering` before writing.

### Time base convention

Everything uses `ProcessInfo.systemUptime` or `CMClockGetHostTimeClock()`
as the reference clock. `EventRecorder` and `CursorSampler` expose a `t`
in seconds-from-recording-start (with pause offset subtracted), which is
the same time base the editor uses for seeking. Don't mix wall-clock
(`Date().timeIntervalSince1970`) into sample timestamps.

## Module layout

| Folder | Responsibility |
| --- | --- |
| `Mentor/App/` | `AppDelegate` (entry point, Apple Event handling, activation-policy flipping), `MenuBarController`, `MentorDebug` log |
| `Mentor/Capture/` | `CaptureCoordinator`, `ScreenCapture` (SCStream), `CameraCapture` (AVCaptureSession), `CaptureContention` (detect Granola/Wispr/etc holding the mic), `SampleBufferRetiming` |
| `Mentor/Recording/` | Raw + audio writers, `EventRecorder`, `CursorSampler`, `RecordingBundle` layout, `TeleprompterController` |
| `Mentor/Soundboard/` | Soundboard engine + cues + hotkey binding |
| `Mentor/Editor/` | `RecordingProject`, `EditorComposition`, `LiveCompositor`, `EditorViewModel`, keyframe models, `SilenceAnalyzer`, `SourceCoordinateMapper`, `TrimMap` |
| `Mentor/Rendering/` | `FinalRenderer` (reader → compositor → writer), `ExportQuality`, `SRTFormatter` |
| `Mentor/UI/` | SwiftUI/AppKit windows (Settings, Soundboard, SourcePicker, RegionSelector, Countdown, RecordingBorder, WebcamPreview, Teleprompter) |
| `Mentor/Hotkeys/` | `GlobalHotkey` — Carbon `RegisterEventHotKey` wrapper |
| `Mentor/Settings/` | `Settings` — UserDefaults-backed singleton, posts `Settings.didChange` notification |

## Entitlements + TCC

- `Mentor.entitlements`: camera + mic + audio-input + hardened runtime.
  **Sandbox is off intentionally** — ScreenCaptureKit, Carbon hotkeys,
  and `NSEvent` global monitors all work cleaner unsandboxed for DMG
  distribution.
- TCC prompts required:
  - Camera, Microphone — webcam + mic capture.
  - Screen Recording — `SCStream`.
  - Accessibility — `NSEvent.addGlobalMonitorForEvents` (clicks / keys
    feed the event log and soundboard hotkeys). Triggered at launch via
    `AXIsProcessTrustedWithOptions`.

**Keep signing identity stable across builds** — ad-hoc signing
reshuffles the CDHash every compile and re-prompts for every TCC grant.
`project.yml` pins `CODE_SIGN_STYLE: Manual` + Developer ID for this
reason.

## LSUIElement gotchas

This is a menu-bar-only app by default (`LSUIElement: true`). That means:
- **No main menu bar** unless we install one manually —
  `AppDelegate.buildMainMenu()` handles Cmd+Cut/Copy/Paste/Quit/Hide etc.
  so standard keyboard shortcuts work when an editor window is focused.
- **Menu bar key equivalents only fire when Mentor is frontmost.** Any
  shortcut that should work globally (record toggle, pause/resume) must
  be registered as a Carbon global hotkey via `GlobalHotkey`. If you add
  a new menu item with a keyEquivalent and the user reports "nothing
  happens / system beep," that's the cause.
- **Modal panels open behind other windows.** Sparkle's updater, NSOpen
  panels, NSColorPanel, NSFontPanel all need `NSApp.activate(ignoringOtherApps: true)`
  called before they're shown. See the `Check for Updates` menu-bar
  callback in `AppDelegate` for the pattern.
- **Activation policy flips on editor open.** Opening a `.mentor`
  bundle flips `NSApp.setActivationPolicy(.regular)` so the app appears
  in the Dock and can accept window focus. Closing the last editor
  flips it back to `.accessory`.

## Concurrency

- `@MainActor` on AppDelegate, MenuBarController, all SwiftUI views.
- `CaptureCoordinator` and everything downstream is `@unchecked Sendable`
  with explicit `NSLock`s. The sample-handler callbacks come off
  AV framework queues — do NOT hop to the main actor inside them.
- `Settings.didChange` notification posts on `.main` queue.
- `SWIFT_STRICT_CONCURRENCY: minimal` in `project.yml` — expect warnings
  about `NSLock.lock/unlock()` not being async-safe in `async` contexts.
  They're known + intentional (Swift 6 migration is a separate project).

## Release workflow

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in `project.yml`.
   (Both — `CFBundleVersion` is the monotonic integer Sparkle compares.)
2. Commit the source changes (**don't** stage `Mentor.xcodeproj/` — it's
   gitignored and gets regenerated).
3. `./build-dmg.sh` — regenerates the xcodeproj, clean Release build,
   signs + notarizes + staples, emits the Sparkle `<item>` block at the
   end. Notarization takes 1–5 min.
4. `git tag v1.2.3 && git push && git push --tags`.
5. `gh release create v1.2.3 Mentor.dmg --title "Mentor 1.2.3" --notes "..."`.
6. Paste the `<item>` block into `appcast.xml` at the top of `<channel>`,
   commit as `appcast: publish v1.2.3`, push.

Users with the previous version get the update prompt on their next
daily Sparkle check (or on next launch if they manually click "Check
for Updates").

## Tuning notes / gotchas accumulated so far

- Raw H.264 tracks use **Baseline profile + `AVVideoAllowFrameReorderingKey: false`**
  — minimal encoder latency during live capture.
- Export path uses **High profile + frame-rate hints**. No
  `AVAssetExportSession` — it picks heuristics that produce jittery
  output with mixed-rate sources.
- `AVAudioFile` can't encode AAC directly from non-interleaved float
  mixer taps. Soundboard records to a temp `.caf` and transcodes to
  AAC on stop.
- **`NSColorPanel` / `NSFontPanel` inside a non-activating `NSPanel`**
  (e.g. the teleprompter): the embedded panel blocks focus. Wrap color
  wells in an `ActivatingColorWell` subclass that calls
  `NSApp.activate` in `mouseDown`; for fonts, use a bridge that
  activates before `makeKeyAndOrderFront`.
- **Capture contention**: Granola, Wispr Flow, some VPN clients hold
  the mic/camera permanently. Results in stuttery webcam preview and
  dropped audio. `CaptureContention.detectedOffenders()` surfaces this
  as a warning in the menu, with a "Quit Those Apps" alert. If user
  reports capture jitter, check this before blaming code.
- **Debug log**: `MentorDebug.log(...)` writes to `/tmp/mentor-debug.log`,
  reset on each `applicationDidFinishLaunching`. Tail it when
  diagnosing recording failures.
- **Single-instance enforcement**: `AppDelegate` checks for another
  Mentor at launch. If found, forwards any pending `.mentor` open-URLs
  to the existing instance and self-terminates. Xcode-from-rebuild
  duplicates get handled this way.

## When editing — style conventions

- **Comments explain _why_, not _what_.** Existing code leans heavily
  on block comments above non-obvious decisions (lock ordering, PTS
  retiming, why a particular codec setting). Match that voice — future
  maintenance depends on it.
- Swift: 4-space indent. Early-return guards. `@MainActor` marked at
  class level when the whole class is main-actor-bound.
- Never add emojis to files unless asked. User preference.
- Never create docs files (`*.md`, `README`, etc.) unless explicitly
  asked. (This CLAUDE.md was explicitly requested.)
- Commit messages: one-line summary capturing the "why," then bullet
  body with specifics. Trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

## Session workflow expectations

- **Plan before coding** for anything touching the capture pipeline,
  compositor, or renderer. Small isolated changes (new menu item, new
  setting, UI tweak) can go direct.
- **Always build after changes.** `xcodebuild … build 2>&1 | tail -5`
  is enough most of the time. If errors, read the full tail.
- **Relaunch the dev build** after a successful edit if the user asked
  you to test something: `pkill -x Mentor; open <path>/Mentor.app`.
- **Hold uncommitted polish until the next batched ship.** Small
  UX fixes accumulate between releases; commit them together when the
  user says "let's ship."
