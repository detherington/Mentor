# CLAUDE.md — Pepper

Guidance for Claude when working in this repo. Keep this file lean — it's
read at the start of every session.

## What this is

Native macOS menu-bar app: Loom-style screen + webcam + mic + system-audio
recording, with a built-in editor (smart zoom, webcam overlays, title cards,
teleprompter, soundboard). Swift + AppKit + SwiftUI, ScreenCaptureKit for
screen, AVFoundation for camera/mic, custom `AVVideoCompositing` for
compositing, Sparkle for auto-update.

Distribution: same model as Muesli. Orbis serves releases from
`https://sbsorbis.com/download/pepper/` (Sparkle appcast + update zips +
DMGs); its Pepper download page links the newest DMG. The repo is still
named `Mentor` (the app's working name before 2.0). Shows in the Dock with
a main window (`UI/Home/`: record, recent recordings, devices, Orbis) that
opens at launch and on a Dock click. Settings › "Hide Pepper from the Dock"
makes it menu-bar only (no window at launch; `.regular` only while one of
its windows is open, via `DockPresence`). `LSUIElement` stays true so a
hidden Dock icon never flashes at launch; the policy is set at startup.

Single-maintainer project; ship cadence is "whenever a feature's ready."
Version is `MARKETING_VERSION` in `project.yml` — currently 1.2.2. The
build number (`CURRENT_PROJECT_VERSION`) is a UTC `YYYYMMDDHHMM`
timestamp set by the release script.

## Source of truth is `project.yml`

**The `.xcodeproj` is gitignored and regenerated from `project.yml` via
XcodeGen on every release build.** Do not edit `project.pbxproj` expecting
changes to persist — they'll be wiped by `scripts/release.sh`'s xcodegen step.
If you add a new Swift file, it should be picked up automatically by the
`sources: [path: Pepper]` rule; you only need to touch `project.yml` to
add a new top-level folder, framework dep, or Info.plist key.

That said, when iterating locally during a session, the current pbxproj
may have been edited by hand (e.g. to add a file that didn't exist yet)
— rebuilding with `xcodebuild` uses whatever's on disk. A regeneration
only happens during `scripts/release.sh`.

## Build / run / ship

| Action | Command |
| --- | --- |
| Debug build | `xcodebuild -project Pepper.xcodeproj -scheme Pepper -configuration Debug -destination 'platform=macOS' build` |
| Launch dev build | `pkill -x Pepper; open <DerivedData>/Build/Products/Debug/Pepper.app` |
| Regenerate xcodeproj | `xcodegen generate` (Homebrew, or `.local/bin/` via `scripts/bootstrap.sh`) |
| Pre-release checks only | `scripts/release.sh --check` |
| Ship a release | `scripts/release.sh`, upload, `scripts/release.sh --verify` (see "Release workflow") |

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

Live capture writes **only** the `.pepper` sidecar bundle (raw tracks +
JSON event logs). The composited MP4 is rendered post-capture by
`FinalRenderer` using `AVAssetReader` + `AVAssetWriter` + `LiveCompositor`.
Rationale: three concurrent HW encoders (screen, webcam, composited) causes
visible jitter on M4-base; one live encoder per raw track is fine.

```
~/Movies/Pepper/
├── Pepper_<timestamp>.mp4            composited final (shareable)
└── Pepper_<timestamp>.pepper/        sidecar bundle (editable)
    ├── screen.mov                    H.264 High, 60fps, frame-reordering off
    ├── webcam.mov                    H.264, 30fps
    ├── mic.m4a                       AAC
    ├── system.m4a                    AAC (optional)
    ├── soundboard.m4a                AAC (only if cues fired)
    ├── soundboard-events.json        cue fire log
    ├── events.json                   clicks, keys, app focus, modifiers
    ├── cursor.json                   30 Hz mouse-location samples
    ├── talking-head.json             manual talking-head moments
    ├── zoom.json                     zoom keyframes (auto + edited)
    ├── edit-state.json               editor look: trim, cuts, webcam, title cards, styles
    ├── transcription.json            on-device SpeechAnalyzer output
    ├── mic_cleaned.caf               noise-reduced mic (editor, on demand)
    └── metadata.json                 source info, webcam layout, dims
```

The teleprompter script is app-wide (UserDefaults), not per-recording.

### CaptureCoordinator is the central hub

`Pepper/Capture/CaptureCoordinator.swift` owns: ScreenCapture (SCStream),
CameraCapture (AVCaptureSession), the current `RecordingSession` (the
four `TrackWriter`s, event/cursor recorders, bundle, metadata — installed
and torn down as one value), the `PauseClock`, and the soundboard
reference. Sample handlers live on the `ScreenCaptureDelegate` /
`CameraCaptureDelegate` extensions and are the hot path — any work done
here has to be lock-safe and fast.

Locks — never hold more than one at a time:
- `pipelineLock` — the `session`
- `PauseClock`'s own lock — pause state + the recording's time origin
- `stateLock` — `_isRecording` / `_isStarting` / interruption flag
- `coordStatsLock` — telemetry counters
- `observerLock` — `_cameraFrameObserver` closure
- `micTapLock` — `_micSampleSink` closure

The sample-handler pattern is: grab a snapshot under the lock, release,
then do the actual work — e.g. take `session?.screen` under
`pipelineLock`, then `clock.sampleState(…)`, then append.

### Pause/resume retiming

Pause/resume uses `CMSampleBufferCreateCopyWithNewTiming` via
`SampleBufferRetiming.swift`'s `CMSampleBuffer.retimed(by:)` extension.
`_cumulativePauseOffset` tracks wall-clock time spent paused (via
`CMClockGetHostTimeClock`); every post-pause A/V sample has its PTS
shifted back by that offset so the encoded track has no freeze-frame
gap. `EventRecorder` + `CursorSampler` do the same in TimeInterval space
so their JSON logs stay aligned with retimed video.

### Custom compositor

`Pepper/Editor/LiveCompositor.swift` is an `AVVideoCompositing`
implementation that drives **both** the live editor preview and the
`FinalRenderer` export pass. Each composition owns its own
`LiveCompositor.State` (there is no shared singleton any more) holding
all overlay parameters (webcam layout, zoom keyframes, talking-head
keyframes, title cards, cursor ripples, audio range). The editor writes
to its composition's `State` on inspector changes; the compositor reads
per frame.

Per-frame order: screen → cursor ripples → smart zoom → webcam (with
fade + talking-head interpolation) → title cards → captions → keystroke overlays.

**Watch out:** an editor-initiated export reads the editor's own
`State`, so `applyLayout` bails while `isExporting` is true. Separately,
`FinalRenderer` serialises renders with a private `renderLock` /
`_isRendering` pair — not for state safety, but so the post-recording
auto-bake and an editor export never run two full-rate HW encoders at
once.

### Time base convention

Everything uses `ProcessInfo.systemUptime` or `CMClockGetHostTimeClock()`
as the reference clock. `EventRecorder` and `CursorSampler` expose a `t`
in seconds-from-recording-start (with pause offset subtracted), which is
the same time base the editor uses for seeking. Don't mix wall-clock
(`Date().timeIntervalSince1970`) into sample timestamps.

## Module layout

| Folder | Responsibility |
| --- | --- |
| `Pepper/App/` | `AppDelegate` (entry point + wiring, shortcuts, quit), `Permissions` (read-only status + button-driven requests for Screen Recording, Camera, Mic, Accessibility), `DockPresence` (claims that keep the app `.regular`), `AppRelauncher`, `RecordingFlowController` (picker → countdown → record → stop state machine; on stop opens the editor, then renders the as-recorded MP4 and shows `VideoReadyNotice` if that editor was closed), `EditorWindowManager` (editor windows + activation-policy flipping), `CaptureDeviceMonitor` (camera/mic permissions, hot-plug), `OpenURLRouter` (open-file Apple Events, duplicate-instance hand-off), `MainMenu`, `MenuBarController`, `PepperDebug` log |
| `Pepper/Capture/` | `CaptureCoordinator`, `PauseClock`, `ScreenCapture` (SCStream), `CameraCapture` (AVCaptureSession), `CaptureContention` (detect Granola/Wispr/etc holding the mic), `SampleBufferRetiming` |
| `Pepper/Recording/` | `TrackWriter` (one writer for all four raw tracks), `EventRecorder`, `CursorSampler`, `RecordingBundle` layout, `TeleprompterController` |
| `Pepper/Soundboard/` | Soundboard engine + cues + hotkey binding |
| `Pepper/Editor/` | `RecordingProject`, `EditorComposition`, `LiveCompositor`, `OverlaySettings` (the one value both preview and export render from), `EditorViewModel`, `EditState` + `SidecarStore` (per-recording edits, debounced saves), keyframe models + `RampKeyframe` (shared zoom/talking-head editing rules), `SilenceAnalyzer`, `SourceCoordinateMapper`, `TrimMap`; `EditorView` (window toolbar: details, Send to Orbis, Export) with `Inspector/` (`EditorInspector`: plain-language feature rows with switches, one open at a time via `vm.openInspectorFeature`, plus Quick polish; timeline/preview clicks open the matching row), `Timeline/`, `ExportSheet` (+ the save panel's Quality accessory) |
| `Pepper/Rendering/` | `FinalRenderer` (reader → compositor → writer), `ExportQuality`, `SRTFormatter` |
| `Pepper/Orbis/` | "Export to Orbis": `OrbisAccount` (connection owner — OAuth 2.1 PKCE + loopback sign-in as client `pepper-mac`, scope `videos`, same flow as Muesli; refresh/revoke), `OAuthLoopbackServer`, `OrbisClient` (REST; asks `OrbisAccount` for a credential per request), `OrbisExportController` (FinalRenderer → presigned R2 PUT → ingest-assets), `OrbisExportSheet`, `OrbisKeychain` (refresh token keyed per host, never UserDefaults), `OrbisSettings` (host + last-used form values). No custom URL scheme — an old token-delivery link was a token-injection hole |
| `Pepper/UI/` | `Home/` (main window: `HomeWindowController` — hides while a recording starts, back if it's cancelled — `HomeModel`, `HomeView`, in the setup/sign-in page look); SwiftUI/AppKit windows (Settings, Soundboard, SourcePicker, RegionSelector, Countdown, RecordingBorder, WebcamPreview, Teleprompter, VideoReadyNotice — Pepper's own card, not a system notification, so no permission prompt); `Onboarding/` (setup walkthrough, modelled on Muesli's); `Brand` (SBS tokens shared with Muesli: colorsets, cobalt `AccentColor` app-wide, Nantes font in `Resources/Fonts`, Neon/Quiet button styles, `brandCard`/`brandKicker`/`brandTimecode`). The editor follows Muesli's rules: native toolbar/forms/menus/sheets; ground strips (timeline, inspector) carrying surface cards; one Neon CTA (Quick polish); Persimmon = live/playhead, Violet = automatic (zooms), Emerald = you (full-screen moments), Teal = caption blocks. Recording indicators (the border, the menu-bar record icon) stay system red on purpose: red is universally "recording" |
| `Pepper/Hotkeys/` | `GlobalHotkey` — Carbon `RegisterEventHotKey` wrapper |
| `Pepper/Settings/` | `Settings` — UserDefaults-backed singleton, posts `Settings.didChange` notification |

## Entitlements + TCC

- `Pepper.entitlements`: camera + mic + audio-input + hardened runtime.
  **Sandbox is off intentionally** — ScreenCaptureKit, Carbon hotkeys,
  and `NSEvent` global monitors all work cleaner unsandboxed for DMG
  distribution.
- TCC prompts required:
  - Camera, Microphone — webcam + mic capture.
  - Screen Recording — `SCStream`.
  - Accessibility — `NSEvent.addGlobalMonitorForEvents` (clicks / keys
    feed the event log and soundboard hotkeys). The soundboard's key
    monitors run only during a recording or while its window is open.
  - Speech Recognition — captions on macOS 14/15 only (legacy
    `SFSpeechRecognizer`). `SpeechAnalyzer` on 26+ needs none, so
    `CaptionTranscriber` never asks there. Where it's needed it is asked
    for only from a button whose note says macOS will ask
    (`CaptionTranscriber.willAskForPermission`).
- **Never ask macOS and open System Settings at once** (Muesli's rule):
  macOS's own request then sits unanswered behind the windows. Screen
  Recording and Accessibility ask once per launch and open the pane only
  if `SystemPrompts` sees no request on screen; afterwards, the pane.
  "Asked" is never saved: preferences outlive deleting the app and
  resetting its permissions, and a stale flag would open a pane Pepper
  isn't listed in. Read permission state live; don't cache it.
  `Permissions.openSettings` brings a request already up to the front
  instead of opening the pane over it.
- **Nothing prompts at launch.** The setup walkthrough (`Onboarding/`,
  shown until `Settings.hasCompletedOnboarding`; Settings › Setup reopens
  it) asks for each permission from a button. A camera/mic skipped there
  is asked for when recording starts; a failed source list (Screen
  Recording off, or on but not applied until relaunch) gets an alert with
  Quit & Reopen.
- **Review hooks (Debug builds, render then quit, work alongside a
  running Pepper):** `open -n Pepper.app --args
  -pepper.debug.renderOnboarding <dir>` writes every setup step (granted
  and un-granted); `-pepper.debug.renderEditor <dir>
  -pepper.debug.renderEditorBundle <recording.pepper>` writes the editor
  window with each inspector row open (editor size and position are
  remembered, the render resizes to 1280×860); add `-pepper.debug.renderPolish
  YES` to also run Quick polish and render its report (it writes zooms
  and captions into the bundle, so point it at a copy). The video area
  renders black. `-pepper.debug.renderReadyNotice <dir>` writes the
  "video is ready" card, light and dark; `-pepper.debug.renderHome <dir>`
  the main window (run the binary directly if `open -n` won't block on it;
  permissions then read as not granted). With the editor hook,
  `-pepper.debug.renderExportTo <file.mp4>` runs the editor's own export
  (as Export and Send to Orbis do) and logs OK or the error;
  `-pepper.debug.renderExportTrimInNs <ns>`, `-pepper.debug.renderExportCutNs
  <start,end>`, `-pepper.debug.renderExportTrimIn <s>` and
  `-pepper.debug.renderExportCleanAudio YES` set up the edit first.

**Keep signing identity stable across builds** — ad-hoc signing
reshuffles the CDHash every compile and re-prompts for every TCC grant.
`project.yml` pins `CODE_SIGN_STYLE: Manual` + Developer ID for this
reason.

## LSUIElement gotchas

`LSUIElement: true`, and menu-bar only when the Dock icon is hidden. That means:
- **No main menu bar** unless we install one manually —
  `MainMenu.build()` handles Cmd+Cut/Copy/Paste/Quit/Hide, Settings (⌘,),
  Open Recording (⌘O) and editor Undo/Redo (their own actions, not
  `undo:`) so standard keyboard shortcuts work when an editor window is
  focused.
- **Menu bar key equivalents only fire when Pepper is frontmost.** Any
  shortcut that should work globally (record toggle, pause/resume) must
  be registered as a Carbon global hotkey via `GlobalHotkey`. If you add
  a new menu item with a keyEquivalent and the user reports "nothing
  happens / system beep," that's the cause.
- **Modal panels open behind other windows.** Sparkle's updater, NSOpen
  panels, NSColorPanel, NSFontPanel all need `NSApp.activate(ignoringOtherApps: true)`
  called before they're shown. See the `Check for Updates` menu-bar
  callback in `AppDelegate` for the pattern.
- **Activation policy goes through `DockPresence`.** `.regular` unless
  the Dock icon is hidden; then the main window, editors, the open panel
  and the setup walkthrough each `DockPresence.claim` so the app is
  `.regular` (Dock, key focus) while they're open, and it drops back to
  `.accessory` when the last claim is released. Don't call
  `setActivationPolicy` directly.

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

Same model as Muesli (`~/Muesli/scripts/release.sh`, docs/DEPLOYMENT.md §7).

1. Bump `MARKETING_VERSION` in `project.yml`. Optional release notes: an
   HTML fragment at `release-notes/<version>.html`. Commit (**don't**
   stage `Pepper.xcodeproj/`). The script refuses a dirty tree.
2. `scripts/release.sh` on `main`:
   - checks: clean tree, tag `vX.Y.Z` unused, version not already in
     `dist/appcast.xml`, SUFeedURL is the Orbis feed, `main` up to date;
   - clean Release build with `CURRENT_PROJECT_VERSION` = UTC timestamp;
     inside-out signing (Sparkle helpers keep their own entitlements);
   - notarize + staple the app (profile `Picsy`, or
     `PEPPER_NOTARY_PROFILE`), zip it with `ditto --sequesterRsrc`, build
     `dist/installer/Pepper-X.Y.Z.dmg` from the stapled app, notarize +
     staple that;
   - `generate_appcast --account ed25519` over `dist/` (refuses if the
     Keychain key doesn't match `SUPublicEDKey`), then stages
     `dist/upload-X.Y.Z/` (appcast, zip, DMG, new deltas), tags, pushes.
3. The user uploads `dist/upload-X.Y.Z/*` to the Orbis Replit project's
   `client/public/download/pepper/`, replacing `appcast.xml`, and
   redeploys. Files only reach production with a deploy.
4. `scripts/release.sh --verify` — confirms Orbis serves the appcast, zip
   and DMG with matching sizes and real content types (Orbis used to
   answer missing files with 200 + its SPA HTML; it returns 404 now).

`dist/` is gitignored but must be kept between releases: generate_appcast
reads the previous feed and old zips (for deltas) from it.

## Tuning notes / gotchas accumulated so far

- Raw H.264 tracks use **High profile + `AVVideoAllowFrameReorderingKey: false`**
  — not Baseline: Baseline's auto-level tops out below 4K on the Apple
  Silicon HW encoder and throws an uncatchable NSInvalidArgument. No
  reordering keeps per-frame latency at zero during live capture.
- Export path uses **High profile + frame-rate hints**. No
  `AVAssetExportSession` — it picks heuristics that produce jittery
  output with mixed-rate sources.
- **Render time ranges live on the composition's 1/600 s grid.** Trim
  points and marks set from the playhead during playback are in
  nanoseconds; mixed with 600ths, a range's end can round past the last
  frame and the reader rejects the video composition (AVError -11841).
  `FinalRenderer` snaps the `TrimMap` first (`snappedForRendering`).
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
- **Debug log**: `PepperDebug.log(...)` writes to `~/Library/Logs/Pepper/pepper-debug.log`,
  reset on each `applicationDidFinishLaunching`. Tail it when
  diagnosing recording failures.
- **Single-instance enforcement**: `AppDelegate` checks for another
  Pepper at launch. If found, forwards any pending `.pepper` open-URLs
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
  you to test something: `pkill -x Pepper; open <path>/Pepper.app`.
- **Hold uncommitted polish until the next batched ship.** Small
  UX fixes accumulate between releases; commit them together when the
  user says "let's ship."
