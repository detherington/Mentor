import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Phase 3b.2 editor. Live composition from raw screen + webcam tracks,
/// editable webcam overlay inspector, real-time preview.
struct EditorView: View {
    @State private var viewModel: EditorViewModel

    init(project: RecordingProject) {
        _viewModel = State(wrappedValue: EditorViewModel(project: project))
    }

    var body: some View {
        @Bindable var vm = viewModel

        return content(vm: vm)
            .sheet(isPresented: Binding(
                get: { vm.isExporting || vm.exportError != nil },
                set: { if !$0 { vm.exportError = nil } }
            )) {
                ExportSheet(viewModel: vm)
            }
    }

    @ViewBuilder
    private func content(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm

        HSplitView {
            VStack(spacing: 0) {
                ZStack {
                    AVPlayerViewRepresentable(player: vm.player)
                        .frame(minHeight: 320)

                    if vm.isLoading {
                        Color.black.opacity(0.35)
                        ProgressView("Loading composition…")
                            .controlSize(.large)
                            .padding(16)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let err = vm.loadError {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                            Text("Couldn't load this recording")
                                .font(.headline)
                            Text(err.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Divider()

                timeline(vm: vm)
            }
            .frame(minWidth: 600)

            inspector(vm: vm)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        }
        .frame(minWidth: 960, minHeight: 600)
        .focusable()
        // Suppress the system-drawn focus ring that `.focusable()` would
        // otherwise paint around the whole editor — it's useful for key
        // routing but ugly on a full-window scope, and gets redraw-stale
        // during window resize.
        .focusEffectDisabled()
        // Pro-editor navigation: space toggles play (already wired via
        // the button's keyboardShortcut), J/K/L = jump-back / pause /
        // jump-forward, arrows step one frame, shift-arrows step one
        // second. Using `.onKeyPress` so these fire whenever the window
        // has key focus without needing hidden buttons per mapping.
        .onKeyPress(.leftArrow) { vm.stepFrame(forward: false); return .handled }
        .onKeyPress(.rightArrow) { vm.stepFrame(forward: true);  return .handled }
        .onKeyPress(keys: ["j"]) { _ in vm.stepFiveSeconds(forward: false); return .handled }
        .onKeyPress(keys: ["k"]) { _ in vm.pausePlayback();                 return .handled }
        .onKeyPress(keys: ["l"]) { _ in vm.stepFiveSeconds(forward: true);  return .handled }
        .onKeyPress(phases: .down) { press in
            // Shift+arrow = 1s step. SwiftUI's `.onKeyPress(.leftArrow)`
            // above fires for unmodified arrows; this catches the shifted
            // variants.
            guard press.modifiers.contains(.shift) else { return .ignored }
            switch press.key {
            case .leftArrow:  vm.stepSecond(forward: false); return .handled
            case .rightArrow: vm.stepSecond(forward: true);  return .handled
            default: return .ignored
            }
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timeline(vm: EditorViewModel) -> some View {
        TimelineView(viewModel: vm)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: 192)
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording").font(.headline)
                    LabeledRow("Captured", value: vm.project.metadata.startDate.formatted(
                        date: .abbreviated, time: .shortened
                    ))
                    LabeledRow("Source", value: vm.project.metadata.source.kind.capitalized)
                    LabeledRow("Screen", value: dimensions(vm.project.metadata.screenPixelSize))
                    LabeledRow("Webcam", value: dimensions(vm.project.metadata.webcamPixelSize))
                    if let events = vm.project.eventLog?.events {
                        LabeledRow("Events logged", value: "\(events.count)")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Webcam overlay").font(.headline)

                    Picker("Shape", selection: $vm.webcamShape) {
                        ForEach(WebcamShape.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("Position", selection: $vm.webcamPosition) {
                        ForEach(WebcamPosition.allCases) { Text($0.label).tag($0) }
                    }

                    HStack {
                        Text("Size")
                        Slider(value: $vm.webcamDiameter, in: vm.diameterMin...vm.diameterMax)
                        Text(points(vm.webcamDiameter, scale: vm.backingScale))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }

                    HStack {
                        Text("Inset")
                        Slider(value: $vm.webcamInset, in: 0...(vm.diameterMax * 0.6))
                        Text(points(vm.webcamInset, scale: vm.backingScale))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }

                    Text("Changes preview live. Original recording is untouched — changes only affect export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(vm.isExporting)

                Divider()

                smartZoomSection(vm: vm)
                    .disabled(vm.isExporting)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Click ripples", isOn: $vm.cursorRipplesEnabled)
                        .font(.headline)
                    Text(cursorRippleHint(vm: vm))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(vm.isExporting)

                Divider()

                webcamTransitionsSection(vm: vm)

                Divider()

                talkingHeadSection(vm: vm)

                Divider()

                audioMixSection(vm: vm)

                Divider()

                titleCardsSection(vm: vm)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Quality", selection: $vm.exportQuality) {
                        ForEach(ExportQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    Text(vm.exportQuality.sizeHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .disabled(vm.isExporting)

                Button {
                    runExportSavePanel(viewModel: vm)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(vm.isExporting || vm.isLoading || vm.loadError != nil)

                Text("Renders a new MP4 with the webcam layout above baked in. Original bundle is untouched.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func dimensions(_ size: RecordingMetadata.CGSizeCodable) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    /// "mm:ss.t" — shared between the inspector + timeline for consistent
    /// time labelling.
    private func timeString(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return "--:--.-" }
        let totalMs = Int(max(0, seconds) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    // MARK: - Webcam transitions section

    @ViewBuilder
    private func webcamTransitionsSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 8) {
            Text("Webcam transitions").font(.headline)

            HStack {
                Text("Fade in")
                Slider(
                    value: Binding(
                        get: { vm.webcamTransitions.fadeIn },
                        set: { vm.webcamTransitions = WebcamTransitions(fadeIn: $0, fadeOut: vm.webcamTransitions.fadeOut) }
                    ),
                    in: 0...3
                )
                Text(String(format: "%.1fs", vm.webcamTransitions.fadeIn))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Fade out")
                Slider(
                    value: Binding(
                        get: { vm.webcamTransitions.fadeOut },
                        set: { vm.webcamTransitions = WebcamTransitions(fadeIn: vm.webcamTransitions.fadeIn, fadeOut: $0) }
                    ),
                    in: 0...3
                )
                Text(String(format: "%.1fs", vm.webcamTransitions.fadeOut))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text("Webcam smoothly appears at the start and disappears at the end. Set to 0 to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(vm.isExporting)
    }

    // MARK: - Smart zoom section

    @ViewBuilder
    private func smartZoomSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Smart zoom", isOn: $vm.zoomEnabled)
                    .font(.headline)
                Spacer()
                Button {
                    vm.addZoomAtPlayhead()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .controlSize(.small)
                .disabled(!vm.canAddZoomAtPlayhead)
                .help("Add a manual zoom keyframe at the playhead, targeting the centre of the canvas.")
            }

            Text(smartZoomHint(vm: vm))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !vm.zoomKeyframes.isEmpty {
                ForEach(vm.zoomKeyframes) { kf in
                    zoomKeyframeRow(kf: kf, vm: vm)
                    Divider()
                }
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        vm.regenerateZoomFromClicks()
                    } label: {
                        Label("Regenerate from clicks", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .controlSize(.small)
                    .help("Wipe any edits and re-run smart-zoom detection on the click log.")
                }
            }
        }
    }

    @ViewBuilder
    private func zoomKeyframeRow(kf: ZoomKeyframe, vm: EditorViewModel) -> some View {
        let holdSeconds = CMTimeGetSeconds(CMTimeSubtract(kf.holdEndTime, CMTimeAdd(kf.startTime, kf.inDuration)))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    vm.seek(to: kf.peakStartTime)
                } label: {
                    Text(timeString(kf.startTime))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Jump to this zoom")

                Spacer()

                Button {
                    vm.removeZoomKeyframe(id: kf.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            HStack {
                Text("Hold")
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { max(0.25, holdSeconds) },
                        set: { v in vm.setZoomKeyframeHold(id: kf.id, hold: CMTime(seconds: v, preferredTimescale: 600)) }
                    ),
                    in: 0.25...10
                )
                Text(String(format: "%.1fs", holdSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            HStack {
                Text("Scale")
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(kf.scale) },
                        set: { v in vm.setZoomKeyframeScale(id: kf.id, scale: CGFloat(v)) }
                    ),
                    in: 1.1...2.5
                )
                Text(String(format: "%.2f×", kf.scale))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - Audio mix section

    @ViewBuilder
    private func audioMixSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        let hasSoundboard = (vm.project.soundboardLog != nil)
            || FileManager.default.fileExists(atPath: vm.project.bundleURL.appendingPathComponent("soundboard.m4a").path)

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio mix").font(.headline)
                Spacer()
                Button {
                    vm.audioMixVolumes = .unity
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Set all tracks to unit gain")
            }

            mixSlider(
                label: "Mic",
                systemImage: "mic.fill",
                value: Binding(
                    get: { Double(vm.audioMixVolumes.mic) },
                    set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                        mic: Float(v),
                        system: vm.audioMixVolumes.system,
                        soundboard: vm.audioMixVolumes.soundboard
                    )}
                )
            )
            mixSlider(
                label: "System",
                systemImage: "speaker.wave.2.fill",
                value: Binding(
                    get: { Double(vm.audioMixVolumes.system) },
                    set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                        mic: vm.audioMixVolumes.mic,
                        system: Float(v),
                        soundboard: vm.audioMixVolumes.soundboard
                    )}
                )
            )
            if hasSoundboard {
                mixSlider(
                    label: "Soundboard",
                    systemImage: "music.note.list",
                    value: Binding(
                        get: { Double(vm.audioMixVolumes.soundboard) },
                        set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                            mic: vm.audioMixVolumes.mic,
                            system: vm.audioMixVolumes.system,
                            soundboard: Float(v)
                        )}
                    )
                )
            }

            Text("Balances the three audio sources in the preview and the exported MP4. 0 mutes, 1 is original volume, values above 1 amplify (watch for clipping).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(vm.isExporting)
    }

    @ViewBuilder
    private func mixSlider(label: String, systemImage: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...2)
            Text(String(format: "%.2f×", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: - Talking head section

    @ViewBuilder
    private func talkingHeadSection(vm: EditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Talking head").font(.headline)
                Spacer()
                Button {
                    vm.addTalkingHeadAtPlayhead()
                } label: {
                    Label("Add at playhead", systemImage: "plus.circle")
                }
                .controlSize(.small)
                .disabled(!vm.canAddTalkingHeadAtPlayhead)
            }

            if vm.talkingHeadKeyframes.isEmpty {
                Text("Grow the webcam to fill the frame for a moment. Scrub to where you want it and click \"Add at playhead\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.talkingHeadKeyframes) { kf in
                    talkingHeadRow(kf: kf, vm: vm)
                    Divider()
                }
                Text("Add as many as you want. If the playhead sits inside an existing moment, the next one lands right after it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(vm.isExporting)
    }

    @ViewBuilder
    private func talkingHeadRow(kf: TalkingHeadKeyframe, vm: EditorViewModel) -> some View {
        let holdSeconds = CMTimeGetSeconds(CMTimeSubtract(kf.holdEndTime, CMTimeAdd(kf.startTime, kf.inDuration)))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    vm.seek(to: kf.peakStartTime)
                } label: {
                    Text(timeString(kf.startTime))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("Jump to this moment")

                Spacer()

                Button {
                    vm.removeTalkingHeadKeyframe(id: kf.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            HStack {
                Text("Hold")
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { max(0.25, holdSeconds) },
                        set: { v in
                            vm.setTalkingHeadHold(
                                id: kf.id,
                                hold: CMTime(seconds: v, preferredTimescale: 600)
                            )
                        }
                    ),
                    in: 0.5...10
                )
                Text(String(format: "%.1fs", holdSeconds))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }

            HStack {
                Text("Size")
                    .frame(width: 44, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(kf.targetDiameterFraction) },
                        set: { v in
                            vm.setTalkingHeadDiameterFraction(id: kf.id, fraction: CGFloat(v))
                        }
                    ),
                    in: 0.2...0.95
                )
                Text(String(format: "%.0f%%", kf.targetDiameterFraction * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    // MARK: - Title cards section

    @ViewBuilder
    private func titleCardsSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 14) {
            Text("Title cards").font(.headline)

            cardEditor(
                label: "Start card",
                card: Binding(get: { vm.startCard }, set: { vm.startCard = $0 })
            )

            cardEditor(
                label: "End card",
                card: Binding(get: { vm.endCard }, set: { vm.endCard = $0 })
            )

            Text("Cards fade between solid screen and the recording. Only included in the exported MP4 — auto-rendered recordings have no cards.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(vm.isExporting)
    }

    @ViewBuilder
    private func cardEditor(label: String, card: Binding<TitleCard>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: card.enabled)
                .font(.subheadline.weight(.semibold))

            if card.wrappedValue.enabled {
                TextField("Title", text: card.title)
                    .textFieldStyle(.roundedBorder)
                TextField("Subtitle (optional)", text: card.subtitle)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    ColorPicker("Text", selection: Binding(
                        get: { card.wrappedValue.textColor.swiftUIColor },
                        set: { card.wrappedValue.textColor = ColorRGBA(swiftUI: $0) }
                    ))
                    ColorPicker("Background", selection: Binding(
                        get: { card.wrappedValue.backgroundColor.swiftUIColor },
                        set: { card.wrappedValue.backgroundColor = ColorRGBA(swiftUI: $0) }
                    ))
                }

                HStack {
                    Text("Fade")
                    Slider(value: card.fadeDuration, in: 0.5...4)
                    Text(String(format: "%.1fs", card.wrappedValue.fadeDuration))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }

    private func cursorRippleHint(vm: EditorViewModel) -> String {
        let n = vm.cursorRipples.count
        if n == 0 {
            return "No clicks logged for this recording — nothing to ripple."
        }
        return "\(n) click\(n == 1 ? "" : "s") will pulse a yellow ring on screen."
    }

    /// Explain *why* there are zero zoom keyframes. The likely culprit
    /// changes with the source kind + how the recording was made, and a
    /// generic "no clicks detected" message was sending users to check
    /// permissions that were already granted.
    private func smartZoomHint(vm: EditorViewModel) -> String {
        if !vm.zoomKeyframes.isEmpty {
            let n = vm.zoomKeyframes.count
            return "\(n) auto-generated zoom moment\(n == 1 ? "" : "s"). Click the purple pills in the timeline to jump to one."
        }
        let log = vm.project.eventLog
        let clicks = log?.events.filter { $0.type == "click" }.count ?? 0
        let kind = vm.project.metadata.source.kind
        let hasFrame = vm.project.metadata.source.windowFrameWidth != nil
        if clicks == 0 {
            return "No clicks were logged during this recording. Smart zoom needs the global Accessibility permission so Mentor can record click positions."
        }
        if kind == "window" && !hasFrame {
            return "\(clicks) clicks were logged, but this recording was made before window-position tracking was added. Re-record (or capture a Display) to get smart zoom."
        }
        return "\(clicks) clicks logged but none fell inside the captured area — smart zoom found nothing to focus on."
    }

    private func points(_ pixels: CGFloat, scale: CGFloat) -> String {
        let pts = Int(pixels / max(scale, 1))
        return "\(pts)pt"
    }

    // MARK: - Export save panel

    @MainActor
    private func runExportSavePanel(viewModel vm: EditorViewModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = vm.suggestedExportFilename
        panel.canCreateDirectories = true
        panel.directoryURL = vm.suggestedExportDirectory
        panel.title = "Export Edited Video"
        panel.message = "Render the composited MP4 with the webcam layout above."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.startExport(to: url)
    }

    /// Direct NSViewRepresentable wrapper around `AVPlayerView` — sidesteps
    /// the SwiftUI `VideoPlayer` internal class that fails to resolve
    /// `AVPlayerView` on some configurations.
    private struct AVPlayerViewRepresentable: NSViewRepresentable {
        let player: AVPlayer

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.player = player
            view.controlsStyle = .inline
            view.videoGravity = .resizeAspect
            view.showsFullScreenToggleButton = true
            return view
        }

        func updateNSView(_ nsView: AVPlayerView, context: Context) {
            if nsView.player !== player {
                nsView.player = player
            }
        }
    }
}

private struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }
}

// MARK: - Timeline

private struct TimelineView: View {
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

            GeometryReader { geo in
                zoomLane(width: geo.size.width)
            }
            .frame(height: 18)

            GeometryReader { geo in
                talkingHeadLane(width: geo.size.width)
            }
            .frame(height: 14)

            GeometryReader { geo in
                cueLane(width: geo.size.width)
            }
            .frame(height: 14)

            controls
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
                DraggableTalkingHeadPill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width
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
                DraggableZoomPill(
                    viewModel: viewModel,
                    kf: kf,
                    trackWidth: width
                )
            }
        }
    }

    // MARK: Header (time labels)

    @ViewBuilder
    private var header: some View {
        HStack {
            Text(timeString(viewModel.currentTime))
                .font(.caption.weight(.medium))
                .monospacedDigit()
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
        }
    }

    // MARK: Track

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let startX = xForTime(viewModel.trimStart, width: width)
        let endX = xForTime(viewModel.trimEnd, width: width)
        let playheadX = xForTime(viewModel.currentTime, width: width)

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
            TrimHandle(leading: true)
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
            TrimHandle(leading: false)
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
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: trackHeight + 6)
                .offset(x: max(0, min(width - 2, playheadX - 1)), y: -3)
                .allowsHitTesting(false)
                .shadow(color: Color.red.opacity(0.4), radius: 2)
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

            Spacer()
        }
        .controlSize(.small)
        .disabled(viewModel.isExporting || viewModel.isLoading)
    }

    // MARK: Helpers

    private var trimSummary: String {
        let start = timeString(viewModel.trimStart)
        let end = timeString(viewModel.trimEnd)
        let dur = CMTimeGetSeconds(CMTimeSubtract(viewModel.trimEnd, viewModel.trimStart))
        let durString = dur.isFinite ? String(format: "%.1fs", dur) : "--"
        return "\(start) → \(end)  (\(durString))"
    }

    private func timeString(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return "--:--.-" }
        let totalMs = Int(max(0, seconds) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    private func xForTime(_ time: CMTime, width: CGFloat) -> CGFloat {
        let total = CMTimeGetSeconds(viewModel.duration)
        guard total > 0, time.isValid, !time.isIndefinite else { return 0 }
        let t = CMTimeGetSeconds(time)
        return CGFloat(max(0, min(1, t / total))) * width
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

private struct TrimHandle: View {
    let leading: Bool

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

// MARK: - Draggable keyframe pills

/// Common translator: how much time does `pixels` represent on a
/// `trackWidth`-wide track of `duration` seconds?
private func secondsFor(pixels: CGFloat, trackWidth: CGFloat, duration: CMTime) -> Double {
    guard trackWidth > 0 else { return 0 }
    let total = CMTimeGetSeconds(duration)
    guard total.isFinite, total > 0 else { return 0 }
    return Double(pixels / trackWidth) * total
}

/// Draggable purple zoom pill. Body drag = move the whole keyframe,
/// right-edge drag = extend/shorten the hold duration. Tap seeks.
///
/// Uses `@State` to capture the pre-drag baseline so successive onChanged
/// callbacks don't compound (we apply translation against the original
/// start/end, not the already-moved one).
private struct DraggableZoomPill: View {
    let viewModel: EditorViewModel
    let kf: ZoomKeyframe
    let trackWidth: CGFloat

    @State private var moveBaseline: CMTime?
    @State private var resizeBaseline: CMTime?

    private let pillHeight: CGFloat = 12
    private let resizeGrabWidth: CGFloat = 10

    var body: some View {
        let startX = xFor(kf.startTime)
        let endX   = xFor(kf.endTime)
        let w = max(2, endX - startX)

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.purple.opacity(viewModel.zoomEnabled ? 0.7 : 0.25))

            // Right-edge resize grab — translucent darker strip. Wins
            // hit-testing over the body because it's later in the ZStack.
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: min(resizeGrabWidth, max(2, w - 4)), height: pillHeight)
                .gesture(resizeGesture)
        }
        .frame(width: w, height: pillHeight)
        .offset(x: startX)
        .help("Zoom \(String(format: "%.2f×", kf.scale)) at \(formatTime(kf.startTime)) — drag to move, right-edge to resize")
        .gesture(moveGesture)
        .onTapGesture { viewModel.seek(to: kf.peakStartTime) }
    }

    private var moveGesture: some Gesture {
        // 5px deadband so a click-intended-as-seek doesn't accidentally
        // move the pill by a pixel or two.
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if moveBaseline == nil { moveBaseline = kf.startTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                let newStart = CMTimeAdd(moveBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600))
                viewModel.moveZoomKeyframe(id: kf.id, to: newStart)
            }
            .onEnded { _ in moveBaseline = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeBaseline == nil { resizeBaseline = kf.holdEndTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                let newHoldEnd = CMTimeAdd(resizeBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600))
                let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
                let newHold = CMTimeSubtract(newHoldEnd, holdStart)
                viewModel.setZoomKeyframeHold(id: kf.id, hold: newHold)
            }
            .onEnded { _ in resizeBaseline = nil }
    }

    // MARK: Helpers

    private func xFor(_ t: CMTime) -> CGFloat {
        let total = CMTimeGetSeconds(viewModel.duration)
        guard total > 0, t.isValid, !t.isIndefinite else { return 0 }
        let s = CMTimeGetSeconds(t)
        return CGFloat(max(0, min(1, s / total))) * trackWidth
    }

    private func formatTime(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return "--:--.-" }
        let totalMs = Int(max(0, seconds) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        return String(format: "%02d:%02d.%d", totalSec / 60, totalSec % 60, tenths)
    }
}

/// Draggable pink talking-head pill. Same shape as the zoom pill —
/// separated so the color + callbacks stay simple and static, and so the
/// per-pill `@State` baselines don't leak between lanes.
private struct DraggableTalkingHeadPill: View {
    let viewModel: EditorViewModel
    let kf: TalkingHeadKeyframe
    let trackWidth: CGFloat

    @State private var moveBaseline: CMTime?
    @State private var resizeBaseline: CMTime?

    private let pillHeight: CGFloat = 10
    private let resizeGrabWidth: CGFloat = 10

    var body: some View {
        let startX = xFor(kf.startTime)
        let endX   = xFor(kf.endTime)
        let w = max(2, endX - startX)

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.pink.opacity(0.7))

            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: min(resizeGrabWidth, max(2, w - 4)), height: pillHeight)
                .gesture(resizeGesture)
        }
        .frame(width: w, height: pillHeight)
        .offset(x: startX)
        .help("Talking head at \(formatTime(kf.startTime)) — drag to move, right-edge to resize")
        .gesture(moveGesture)
        .onTapGesture { viewModel.seek(to: kf.peakStartTime) }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if moveBaseline == nil { moveBaseline = kf.startTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                let newStart = CMTimeAdd(moveBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600))
                viewModel.moveTalkingHeadKeyframe(id: kf.id, to: newStart)
            }
            .onEnded { _ in moveBaseline = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeBaseline == nil { resizeBaseline = kf.holdEndTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                let newHoldEnd = CMTimeAdd(resizeBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600))
                let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
                let newHold = CMTimeSubtract(newHoldEnd, holdStart)
                viewModel.setTalkingHeadHold(id: kf.id, hold: newHold)
            }
            .onEnded { _ in resizeBaseline = nil }
    }

    private func xFor(_ t: CMTime) -> CGFloat {
        let total = CMTimeGetSeconds(viewModel.duration)
        guard total > 0, t.isValid, !t.isIndefinite else { return 0 }
        let s = CMTimeGetSeconds(t)
        return CGFloat(max(0, min(1, s / total))) * trackWidth
    }

    private func formatTime(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return "--:--.-" }
        let totalMs = Int(max(0, seconds) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        return String(format: "%02d:%02d.%d", totalSec / 60, totalSec % 60, tenths)
    }
}

/// Mic-amplitude strip drawn behind the trim track. Treats `samples`
/// (0...1 peak per bucket) as a symmetric silhouette around the vertical
/// centre. Empty samples array → blank view, so first-paint happens
/// before the async sampler finishes.
private struct WaveformStripView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }
            let bucketCount = samples.count
            // Each bucket gets a vertical line ~1.5px wide with a small
            // gap. Works out to ~500 buckets visible at typical widths;
            // we downsample by stepping through `samples` if the window
            // is narrower than the sample count.
            let stride = max(1, Int(ceil(Double(bucketCount) / Double(size.width / 2))))
            let lineWidth: CGFloat = 1.5
            let midY = size.height / 2
            let halfHeight = size.height * 0.42  // leave small top/bottom padding

            var path = Path()
            var i = 0
            while i < bucketCount {
                let amp = CGFloat(samples[i])
                let x = size.width * (CGFloat(i) / CGFloat(bucketCount))
                let h = max(1, amp * halfHeight)
                path.move(to: CGPoint(x: x, y: midY - h))
                path.addLine(to: CGPoint(x: x, y: midY + h))
                i += stride
            }
            context.stroke(
                path,
                with: .color(.white.opacity(0.8)),
                lineWidth: lineWidth
            )
        }
    }
}

/// Modal sheet shown over the editor window during export, with progress
/// bar + cancel + error-state handling.
private struct ExportSheet: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let err = viewModel.exportError {
                errorContent(err: err)
            } else {
                progressContent
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    @ViewBuilder
    private var progressContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting edited video")
                    .font(.headline)
                Text("The render runs offline — no time limit on duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        ProgressView(value: viewModel.exportProgress)
            .progressViewStyle(.linear)

        HStack {
            Text("\(Int(viewModel.exportProgress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) {
                viewModel.cancelExport()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func errorContent(err: any Error) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(errorTitle(for: err))
                    .font(.headline)
                Text(err.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        HStack {
            Spacer()
            Button("Close") {
                viewModel.exportError = nil
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func errorTitle(for err: any Error) -> String {
        if case FinalRenderer.RenderError.cancelled = err {
            return "Export cancelled"
        }
        return "Export failed"
    }
}
