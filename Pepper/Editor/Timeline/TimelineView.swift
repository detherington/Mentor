import SwiftUI
import AVFoundation

/// The parts of the editor that depend on the playhead, each its own
/// view. `currentTime` changes ~30×/s during playback, and SwiftUI
/// re-renders whichever view read it: read inline, it re-rendered the
/// whole inspector (including a synchronous title-card image load) and
/// every timeline lane, pill and the waveform on each tick.
struct PlayheadTimeLabel: View {
    let viewModel: EditorViewModel

    var body: some View {
        Text(TimelineMath.timeString(viewModel.currentTime))
            .font(.caption.weight(.medium))
            .monospacedDigit()
    }
}

struct PlayheadLine: View {
    let viewModel: EditorViewModel
    let width: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        let x = TimelineMath.x(for: viewModel.currentTime, duration: viewModel.duration, width: width)
        Rectangle()
            .fill(Color.red)
            .frame(width: 2, height: trackHeight + 6)
            .offset(x: max(0, min(width - 2, x - 1)), y: -3)
            .allowsHitTesting(false)
            .shadow(color: Color.red.opacity(0.4), radius: 2)
    }
}

/// `selectionRange` follows the playhead while a mark is set.
struct SelectionWash: View {
    let viewModel: EditorViewModel
    let width: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        if let sel = viewModel.selectionRange {
            let a = TimelineMath.x(for: sel.start, duration: viewModel.duration, width: width)
            let b = TimelineMath.x(for: sel.end, duration: viewModel.duration, width: width)
            Rectangle()
                .fill(Color.orange.opacity(0.4))
                .frame(width: max(0, b - a), height: trackHeight)
                .offset(x: a)
                .allowsHitTesting(false)
        }
    }
}

/// Enabled only for a non-empty selection — which follows the playhead
/// while a mark is set.
struct CutSelectionButton: View {
    let viewModel: EditorViewModel

    var body: some View {
        Button {
            viewModel.cutSelection()
        } label: {
            Label("Cut", systemImage: "scissors")
        }
        .keyboardShortcut("o", modifiers: .shift)
        .disabled(viewModel.selectionRange == nil)
        .help("Delete selected range (⇧O) — ripples timeline + keyframes")
    }
}

struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel

    private let trackHeight: CGFloat = 40
    private let handleWidth: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            GeometryReader { geo in
                track(width: geo.size.width)
            }
            .frame(height: trackHeight)

            // Secondary lanes — each one is conditional on the
            // viewModel's effective visibility rule (user override +
            // "has data" fallback). Hiding removes the row from the
            // stack so the bottom controls lift up, no empty stripes.
            if viewModel.isTimelineLaneVisible(.zoom) {
                GeometryReader { geo in zoomLane(width: geo.size.width) }
                    .frame(height: 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if viewModel.isTimelineLaneVisible(.talkingHead) {
                GeometryReader { geo in talkingHeadLane(width: geo.size.width) }
                    .frame(height: 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if viewModel.isTimelineLaneVisible(.soundboard) {
                GeometryReader { geo in cueLane(width: geo.size.width) }
                    .frame(height: 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if viewModel.isTimelineLaneVisible(.captions) {
                GeometryReader { geo in captionsLane(width: geo.size.width) }
                    .frame(height: 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if viewModel.isTimelineLaneVisible(.keystrokes) {
                GeometryReader { geo in keystrokesLane(width: geo.size.width) }
                    .frame(height: 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            controls
        }
        .animation(
            .easeInOut(duration: 0.18),
            value: [
                viewModel.isTimelineLaneVisible(.zoom),
                viewModel.isTimelineLaneVisible(.talkingHead),
                viewModel.isTimelineLaneVisible(.soundboard),
                viewModel.isTimelineLaneVisible(.captions),
                viewModel.isTimelineLaneVisible(.keystrokes)
            ]
        )
    }

    // MARK: Keystroke lane

    @ViewBuilder
    private func keystrokesLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))

            // Each chip is a point-in-time event, like a soundboard
            // cue. Render as a fixed-width yellow capsule so a burst
            // of keystrokes reads as a cluster rather than one long
            // bar. Width of 4pt keeps even a rapid ⌘S⌘Enter duo
            // distinguishable.
            ForEach(viewModel.keystrokeChips) { chip in
                let x = xForTime(chip.time, width: width)
                Capsule()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 4, height: 10)
                    .offset(x: max(0, min(width - 4, x - 2)))
                    .help("\(timeString(chip.time)): \(chip.label)")
                    .onTapGesture {
                        viewModel.seek(to: chip.time)
                    }
            }
        }
    }

    // MARK: Caption lane

    @ViewBuilder
    private func captionsLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))

            ForEach(viewModel.transcription?.lines ?? []) { line in
                let startTime = CMTime(seconds: line.startSeconds, preferredTimescale: 600)
                let endTime = CMTime(seconds: line.endSeconds, preferredTimescale: 600)
                let a = xForTime(startTime, width: width)
                let b = xForTime(endTime, width: width)
                // Range pill — width matches the line's display duration,
                // collapsed to a minimum 3pt so very short lines stay
                // clickable. Fill colour flips to accent when this line
                // is the focused one, so after clicking the pill you can
                // see which row the inspector jumped to.
                let isFocused = viewModel.focusedCaptionLineId == line.id
                let w = max(3, b - a)
                RoundedRectangle(cornerRadius: 2)
                    .fill(isFocused ? Color.accentColor.opacity(0.9) : Color.blue.opacity(0.6))
                    .frame(width: w, height: 10)
                    .offset(x: max(0, min(width - w, a)))
                    .help("\(timeString(startTime)): \(line.text)")
                    .onTapGesture {
                        viewModel.seek(to: startTime)
                        viewModel.focusedCaptionLineId = line.id
                    }
            }
        }
    }

    // MARK: Soundboard cue lane

    @ViewBuilder
    private func cueLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))

            ForEach(viewModel.project.soundboardLog?.events ?? [], id: \.cueID) { fire in
                let cueTime = CMTime(seconds: fire.t, preferredTimescale: 600)
                let x = xForTime(cueTime, width: width)
                // Fixed-width orange pill centred on the fire instant —
                // cue triggers are point-in-time events, not ranges.
                Capsule()
                    .fill(Color.orange.opacity(0.85))
                    .frame(width: 6, height: 10)
                    .offset(x: max(0, min(width - 6, x - 3)))
                    .help("\(fire.cueName) • \(timeString(cueTime))")
                    .onTapGesture {
                        viewModel.seek(to: cueTime)
                    }
            }
        }
    }

    // MARK: Talking-head keyframe lane

    @ViewBuilder
    private func talkingHeadLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.06))

            ForEach(viewModel.talkingHeadKeyframes) { kf in
                KeyframePill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width,
                    height: 10,
                    color: .pink.opacity(0.7),
                    help: "Talking head at \(TimelineMath.timeString(kf.startTime)) — drag to move, right-edge to resize",
                    onMove: { viewModel.moveTalkingHeadKeyframe(id: $0, to: $1) },
                    onSetHold: { viewModel.setTalkingHeadHold(id: $0, hold: $1) }
                )
            }
        }
    }

    // MARK: Zoom keyframe lane

    @ViewBuilder
    private func zoomLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.08))

            ForEach(viewModel.zoomKeyframes) { kf in
                KeyframePill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width,
                    height: 12,
                    color: .purple.opacity(viewModel.zoomEnabled ? 0.7 : 0.25),
                    help: "Zoom \(String(format: "%.2f×", kf.scale)) at \(TimelineMath.timeString(kf.startTime)) — drag to move, right-edge to resize",
                    onMove: { viewModel.moveZoomKeyframe(id: $0, to: $1) },
                    onSetHold: { viewModel.setZoomKeyframeHold(id: $0, hold: $1) }
                )
            }
        }
    }

    // MARK: Header (time labels)

    @ViewBuilder
    private var header: some View {
        HStack {
            PlayheadTimeLabel(viewModel: viewModel)
            Spacer()
            Text(trimSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Text(timeString(viewModel.duration))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            laneVisibilityMenu
                .padding(.leading, 6)
        }
    }

    /// Popover-style menu that exposes per-lane Auto/Show/Hide state
    /// plus global Show-all / Hide-all / Reset-to-Auto shortcuts. The
    /// lane's current resolved visibility shows as a checkmark so the
    /// user can tell at a glance what's on screen.
    @ViewBuilder
    private var laneVisibilityMenu: some View {
        Menu {
            ForEach(TimelineLane.allCases) { lane in
                Menu {
                    ForEach(LaneVisibility.allCases, id: \.self) { option in
                        Button {
                            var p = viewModel.timelineLanePrefs
                            p[lane] = option
                            viewModel.timelineLanePrefs = p
                        } label: {
                            if viewModel.timelineLanePrefs[lane] == option {
                                Label(option.menuLabel, systemImage: "checkmark")
                            } else {
                                Text(option.menuLabel)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(lane.menuLabel)
                        Spacer()
                        if viewModel.isTimelineLaneVisible(lane) {
                            Image(systemName: "eye")
                        } else {
                            Image(systemName: "eye.slash")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            Button("Show All Lanes") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.show)
            }
            Button("Hide All Lanes") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.hide)
            }
            Button("Reset to Auto") {
                viewModel.timelineLanePrefs = viewModel.timelineLanePrefs.all(.auto)
            }
        } label: {
            Image(systemName: "square.3.layers.3d.down.forward")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("Choose which timeline lanes to show")
    }

    // MARK: Track

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let startX = xForTime(viewModel.trimStart, width: width)
        let endX = xForTime(viewModel.trimEnd, width: width)

        ZStack(alignment: .leading) {
            // Base track
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.secondary.opacity(0.15))

            // Waveform behind everything else — subtle, doesn't fight
            // with the trim handles or playhead.
            WaveformStripView(samples: viewModel.waveformSamples)
                .frame(width: width, height: trackHeight)
                .opacity(0.45)
                .allowsHitTesting(false)

            // Active trim region highlight
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: max(0, endX - startX))
                .offset(x: startX)

            // Dimmed pre-trim
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, startX))

            // Dimmed post-trim
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .frame(width: max(0, width - endX))
                .offset(x: endX)

            // Interior cuts — rendered as dark hatched regions so they
            // read as "not in the output". Drawn ABOVE the active-trim
            // highlight but BELOW the seek layer + handles.
            ForEach(Array(viewModel.cutRanges.enumerated()), id: \.offset) { _, cut in
                let a = xForTime(cut.start, width: width)
                let b = xForTime(cut.end, width: width)
                ZStack {
                    Rectangle()
                        .fill(Color.black.opacity(0.55))
                    // Diagonal hatch lines in a subtle tint so the
                    // region reads as "cut" even without color.
                    GeometryReader { geo in
                        let size = geo.size
                        let step: CGFloat = 6
                        Path { p in
                            var x: CGFloat = -size.height
                            while x < size.width + size.height {
                                p.move(to: CGPoint(x: x, y: size.height))
                                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                                x += step
                            }
                        }
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                }
                .frame(width: max(0, b - a), height: trackHeight)
                .offset(x: a)
                .allowsHitTesting(false)
            }

            // Active range selection — drawn as an orange wash so it's
            // clearly distinct from trim + cuts. Only visible while the
            // user has hit "Mark" and is scrubbing.
            SelectionWash(viewModel: viewModel, width: width, trackHeight: trackHeight)

            // Click/drag-to-seek layer (below handles)
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let t = timeForX(value.location.x, width: width)
                            viewModel.seek(to: t)
                        }
                )

            // Left trim handle
            TrimHandle()
                .frame(width: handleWidth, height: trackHeight)
                .offset(x: clampHandleOffset(startX - handleWidth / 2, width: width))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let t = timeForX(value.location.x + handleWidth / 2, width: width)
                            viewModel.setTrimStart(t)
                        }
                )

            // Right trim handle
            TrimHandle()
                .frame(width: handleWidth, height: trackHeight)
                .offset(x: clampHandleOffset(endX - handleWidth / 2, width: width))
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let t = timeForX(value.location.x + handleWidth / 2, width: width)
                            viewModel.setTrimEnd(t)
                        }
                )

            // Playhead (non-interactive visual)
            PlayheadLine(viewModel: viewModel, width: width, trackHeight: trackHeight)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 22)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Play / Pause (Space)")

            Divider().frame(height: 16)

            Button {
                viewModel.performUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!viewModel.canUndo)
            .help(undoTooltip)

            Button {
                viewModel.performRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!viewModel.canRedo)
            .help(redoTooltip)

            Divider().frame(height: 16)

            Button {
                viewModel.setTrimStartToCurrent()
            } label: {
                Label("Set In", systemImage: "arrow.down.to.line.compact")
            }
            .keyboardShortcut("i", modifiers: [])
            .help("Set trim in-point to playhead (I)")

            Button {
                viewModel.setTrimEndToCurrent()
            } label: {
                Label("Set Out", systemImage: "arrow.up.to.line.compact")
            }
            .keyboardShortcut("o", modifiers: [])
            .help("Set trim out-point to playhead (O)")

            Button {
                viewModel.clearTrim()
            } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .help("Reset trim to full duration")

            Button {
                viewModel.autoTrimSilence()
            } label: {
                Label("Auto-trim", systemImage: "waveform.path.ecg")
            }
            .help("Re-run silence detection on the mic track")

            Divider().frame(height: 16)

            Button {
                viewModel.markSelectionStart()
            } label: {
                Label("Mark", systemImage: "flag")
            }
            .keyboardShortcut("i", modifiers: .shift)
            .help("Anchor a selection at the playhead (⇧I)")

            CutSelectionButton(viewModel: viewModel)

            Spacer()
        }
        .controlSize(.small)
        .disabled(viewModel.isExporting || viewModel.isLoading)
    }

    // MARK: Helpers

    private var undoTooltip: String {
        let name = viewModel.undoActionName
        return name.isEmpty ? "Undo (⌘Z)" : "Undo \(name) (⌘Z)"
    }

    private var redoTooltip: String {
        let name = viewModel.redoActionName
        return name.isEmpty ? "Redo (⌘⇧Z)" : "Redo \(name) (⌘⇧Z)"
    }

    private var trimSummary: String {
        let start = timeString(viewModel.trimStart)
        let end = timeString(viewModel.trimEnd)
        let dur = CMTimeGetSeconds(CMTimeSubtract(viewModel.trimEnd, viewModel.trimStart))
        let durString = dur.isFinite ? String(format: "%.1fs", dur) : "--"
        return "\(start) → \(end)  (\(durString))"
    }

    private func timeString(_ t: CMTime) -> String {
        TimelineMath.timeString(t)
    }

    private func xForTime(_ time: CMTime, width: CGFloat) -> CGFloat {
        TimelineMath.x(for: time, duration: viewModel.duration, width: width)
    }

    private func timeForX(_ x: CGFloat, width: CGFloat) -> CMTime {
        guard width > 0 else { return .zero }
        let fraction = Double(max(0, min(width, x)) / width)
        let total = CMTimeGetSeconds(viewModel.duration)
        return CMTime(seconds: fraction * total, preferredTimescale: 600)
    }

    private func clampHandleOffset(_ x: CGFloat, width: CGFloat) -> CGFloat {
        max(0, min(width - handleWidth, x))
    }
}

struct TrimHandle: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 18)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 2, x: 0, y: 1)
    }
}
