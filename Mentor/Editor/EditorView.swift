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

                    // Click-to-place overlay for zoom focus points.
                    // Only enters the hit path when a keyframe is
                    // actively being retargeted — otherwise the
                    // AVPlayerView controls work normally.
                    if vm.zoomTargetBeingPlaced != nil {
                        zoomFocusPlacementOverlay(vm: vm)
                    } else if vm.webcamPosition != .hidden {
                        // Drag-to-reposition the inset webcam. Scoped
                        // to the webcam's on-screen rect so AVPlayerView
                        // controls (play/pause bar, scrubber) still
                        // receive clicks everywhere else.
                        webcamDragOverlay(vm: vm)
                    }

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
        //
        // IMPORTANT: SwiftUI's `.onKeyPress` on a parent fires even when
        // a descendant `TextField` has focus. For the character-key
        // shortcuts (J/K/L, and the unshifted variants inside the
        // "phases: .down" block) we guard with `isTextInputFocused()`
        // so typing a letter in a caption field doesn't also jump the
        // timeline. Arrows and ⌘Z are left alone — arrows move the
        // cursor inside the field naturally (their `.handled` still
        // prevents the editor shortcut at field-focus time because
        // TextField consumes arrows first via the responder chain;
        // testing on macOS 26 confirms no duplicate handling).
        .onKeyPress(.leftArrow) {
            if isTextInputFocused() { return .ignored }
            vm.stepFrame(forward: false); return .handled
        }
        .onKeyPress(.rightArrow) {
            if isTextInputFocused() { return .ignored }
            vm.stepFrame(forward: true);  return .handled
        }
        .onKeyPress(keys: ["j"]) { _ in
            if isTextInputFocused() { return .ignored }
            vm.stepFiveSeconds(forward: false); return .handled
        }
        .onKeyPress(keys: ["k"]) { _ in
            if isTextInputFocused() { return .ignored }
            vm.pausePlayback(); return .handled
        }
        .onKeyPress(keys: ["l"]) { _ in
            if isTextInputFocused() { return .ignored }
            vm.stepFiveSeconds(forward: true);  return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Shift+arrow = 1s step. SwiftUI's `.onKeyPress(.leftArrow)`
            // above fires for unmodified arrows; this catches the shifted
            // variants. Skip when a text field is focused so ⇧← / ⇧→
            // for word-selection inside the field still work.
            if press.modifiers.contains(.shift) && !press.modifiers.contains(.command) {
                if isTextInputFocused() { return .ignored }
                switch press.key {
                case .leftArrow:  vm.stepSecond(forward: false); return .handled
                case .rightArrow: vm.stepSecond(forward: true);  return .handled
                default: break
                }
            }
            // ⌘Z / ⌘⇧Z — undo/redo. Deliberately fires regardless of
            // text field focus: macOS users expect ⌘Z to undo app-level
            // state even while editing a field. The text field's own
            // undo is separate (field editor).
            if press.modifiers.contains(.command),
               press.characters.lowercased() == "z" {
                if press.modifiers.contains(.shift) {
                    vm.performRedo()
                } else {
                    vm.performUndo()
                }
                return .handled
            }
            // Esc — drop any in-progress range selection. Still fine in
            // text field focus — Esc doesn't cancel typing.
            if press.key == .escape, vm.selectionRange != nil {
                vm.clearSelection()
                return .handled
            }
            // ⌫ — when a selection is active, cut it. Skip if text
            // field is focused so delete-a-character still works.
            if press.key == .delete || press.key == .deleteForward {
                if isTextInputFocused() { return .ignored }
                if vm.selectionRange != nil {
                    vm.cutSelection()
                    return .handled
                }
            }
            return .ignored
        }
    }

    /// True if the key window's first responder is a text input field
    /// (TextField, SecureField, TextEditor). Used to gate editor
    /// keyboard shortcuts so they don't swallow plain letter keys while
    /// the user is editing a caption line.
    private func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        let responder = window.firstResponder
        // SwiftUI's TextField renders as an NSTextField, whose editing
        // responder is an NSTextView (the shared field editor).
        if responder is NSTextView { return true }
        if responder is NSTextField { return true }
        return false
    }

    // MARK: - Timeline

    @ViewBuilder
    private func timeline(vm: EditorViewModel) -> some View {
        TimelineView(viewModel: vm)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(height: timelineHeight(vm: vm))
            .animation(.easeInOut(duration: 0.18), value: timelineHeight(vm: vm))
    }

    /// Total vertical space the timeline needs for its currently-
    /// visible lanes. Base = header (~18) + padding (20) + main track
    /// (40) + controls (~30) + spacing. Each visible secondary lane
    /// adds its own height + 6pt inter-row spacing.
    private func timelineHeight(vm: EditorViewModel) -> CGFloat {
        var h: CGFloat = 18 + 20 + 40 + 30 + 12
        for lane in TimelineLane.allCases where vm.isTimelineLaneVisible(lane) {
            let rowH: CGFloat = (lane == .zoom) ? 18 : 14
            h += rowH + 6
        }
        return h
    }

    // MARK: - Inspector

    @ViewBuilder
    private func inspector(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm

        ScrollViewReader { proxy in
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

                    webcamBackgroundControls(vm: vm)
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

                cursorHighlightSection(vm: vm)

                webcamTransitionsSection(vm: vm)

                Divider()

                talkingHeadSection(vm: vm)

                Divider()

                audioMixSection(vm: vm)

                Divider()

                captionsSection(vm: vm)

                Divider()

                keystrokesSection(vm: vm)

                Divider()

                cutsSection(vm: vm)

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
            // Timeline caption-pill taps set `focusedCaptionLineId`;
            // scroll this pane so the matching row is on screen. Runs
            // on the next layout pass so the DisclosureGroup inside
            // CaptionEditList has time to expand first.
            .onChange(of: vm.focusedCaptionLineId) { _, newValue in
                guard let id = newValue else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
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
                .help("Add a manual zoom keyframe at the playhead, targeting the centre of the canvas. Uses your current Amount setting for the peak scale.")
            }

            Text(smartZoomHint(vm: vm))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Tuning knobs — live settings that shape both auto-
            // regeneration AND manually-added keyframes at the
            // playhead. Existing keyframes don't update until the user
            // hits "Regenerate from clicks" (destructive — wipes edits).
            DisclosureGroup("Tuning") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Amount").frame(width: 70, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { vm.zoomTuning.scale },
                                set: { var t = vm.zoomTuning; t.scale = $0; vm.zoomTuning = t }
                            ),
                            in: 1.1...2.0
                        )
                        Text(String(format: "%.2f×", vm.zoomTuning.scale))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Hold").frame(width: 70, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { vm.zoomTuning.holdSeconds },
                                set: { var t = vm.zoomTuning; t.holdSeconds = $0; vm.zoomTuning = t }
                            ),
                            in: 0.1...2.5
                        )
                        Text(String(format: "%.1fs", vm.zoomTuning.holdSeconds))
                            .font(.caption.monospacedDigit())
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Sensitivity").frame(width: 70, alignment: .leading)
                        Picker("", selection: Binding(
                            get: { vm.zoomTuning.sensitivity },
                            set: { var t = vm.zoomTuning; t.sensitivity = $0; vm.zoomTuning = t }
                        )) {
                            ForEach(ZoomTuning.Sensitivity.allCases) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    HStack {
                        Spacer()
                        Button {
                            vm.zoomTuning = .default
                        } label: {
                            Text("Reset")
                        }
                        .controlSize(.small)
                        .help("Reset Amount / Hold / Sensitivity to their defaults.")

                        Button {
                            vm.regenerateZoomFromClicks()
                        } label: {
                            Label("Apply to Clicks", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .controlSize(.small)
                        .help("Wipe any edits and re-run smart-zoom detection using these values.")
                    }
                    Text("Amount + Hold also apply to manually-added zooms via the \"Add\" button. Sensitivity only affects Regenerate.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .font(.subheadline)

            if !vm.zoomKeyframes.isEmpty {
                ForEach(vm.zoomKeyframes) { kf in
                    zoomKeyframeRow(kf: kf, vm: vm)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func zoomKeyframeRow(kf: ZoomKeyframe, vm: EditorViewModel) -> some View {
        let holdSeconds = CMTimeGetSeconds(CMTimeSubtract(kf.holdEndTime, CMTimeAdd(kf.startTime, kf.inDuration)))
        let isPlacing = vm.zoomTargetBeingPlaced == kf.id
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
                    if isPlacing {
                        vm.cancelPlacingZoomTarget()
                    } else {
                        vm.beginPlacingZoomTarget(id: kf.id)
                    }
                } label: {
                    Label(
                        isPlacing ? "Cancel" : "Set Focus",
                        systemImage: isPlacing ? "xmark.circle" : "scope"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(isPlacing
                      ? "Cancel focus placement"
                      : "Click a point on the preview to set this zoom's focus")

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

    // MARK: - Captions section

    @ViewBuilder
    private func captionsSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Captions").font(.headline)
                Spacer()
                if vm.isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let log = vm.transcription {
                Toggle("Show captions", isOn: Binding(
                    get: { vm.captionStyle.enabled },
                    set: { var s = vm.captionStyle; s.enabled = $0; vm.captionStyle = s }
                ))

                Text("\(log.lines.count) line\(log.lines.count == 1 ? "" : "s") transcribed on-device (\(log.locale)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Size")
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.captionStyle.fontSizeFraction },
                            set: { var s = vm.captionStyle; s.fontSizeFraction = $0; vm.captionStyle = s }
                        ),
                        in: 0.025...0.08
                    )
                    Text(String(format: "%.1f%%", vm.captionStyle.fontSizeFraction * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Bottom")
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.captionStyle.bottomInsetFraction },
                            set: { var s = vm.captionStyle; s.bottomInsetFraction = $0; vm.captionStyle = s }
                        ),
                        in: 0.01...0.3
                    )
                    Text(String(format: "%.0f%%", vm.captionStyle.bottomInsetFraction * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Button {
                        vm.generateCaptions()
                    } label: {
                        Label("Regenerate", systemImage: "waveform")
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)

                    Button(role: .destructive) {
                        vm.clearCaptions()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)
                }

                // Per-line edit list. Collapsed by default — most
                // transcriptions are a dozen-plus lines and an always-
                // open list would dwarf every other inspector section.
                CaptionEditList(vm: vm, lines: log.lines)

                Toggle("Export .srt alongside MP4", isOn: $vm.exportSRTSidecar)
                    .help("Writes a subtitle sidecar file next to the exported MP4. YouTube / Premiere / Final Cut / DaVinci all accept .srt. Timestamps reflect your trim + cuts.")
            } else {
                Text("Transcribe your narration on-device to burn subtitles into the exported MP4. First run prompts for Speech Recognition permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    vm.generateCaptions()
                } label: {
                    Label("Generate from mic", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .disabled(vm.isTranscribing)
            }

            if let err = vm.transcriptionError {
                Text(err.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                // macOS 26 has a quirk where on-device
                // SFSpeechURLRecognitionRequest can return empty even
                // when Dictation works. Offer an explicit cloud retry.
                if vm.transcriptionErrorIsNoSpeech {
                    Button {
                        vm.generateCaptions(allowCloudFallback: true)
                    } label: {
                        Label("Retry via Apple's cloud", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)
                    Text("Sends this recording's audio to Apple for speech recognition. Only for this one request.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(vm.isExporting)
    }

    // MARK: - Webcam background controls

    @ViewBuilder
    private func webcamBackgroundControls(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Background")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            Picker("", selection: Binding(
                get: { vm.webcamBackgroundStyle.mode },
                set: { var s = vm.webcamBackgroundStyle; s.mode = $0; vm.webcamBackgroundStyle = s }
            )) {
                ForEach(WebcamBackgroundMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch vm.webcamBackgroundStyle.mode {
            case .off:
                Text("Raw webcam passes through to the overlay. No segmentation cost.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .blur:
                HStack {
                    Text("Strength").frame(width: 70, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.webcamBackgroundStyle.blurRadius },
                            set: { var s = vm.webcamBackgroundStyle; s.blurRadius = $0; vm.webcamBackgroundStyle = s }
                        ),
                        in: 4...40
                    )
                    Text("\(Int(vm.webcamBackgroundStyle.blurRadius))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            case .color:
                ColorPicker("Color", selection: Binding(
                    get: {
                        let s = vm.webcamBackgroundStyle
                        return Color(red: s.red, green: s.green, blue: s.blue)
                    },
                    set: { newColor in
                        let nsColor = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                        var s = vm.webcamBackgroundStyle
                        s.red = nsColor.redComponent
                        s.green = nsColor.greenComponent
                        s.blue = nsColor.blueComponent
                        vm.webcamBackgroundStyle = s
                    }
                ))
            case .transparent:
                Text("Background is fully transparent — the screen recording shows through the webcam's shape. Great for a free-floating talking-head look.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.webcamBackgroundStyle.mode != .off {
                Picker("Quality", selection: Binding(
                    get: { vm.webcamBackgroundStyle.qualityLevel },
                    set: { var s = vm.webcamBackgroundStyle; s.qualityLevel = $0; vm.webcamBackgroundStyle = s }
                )) {
                    Text("Fast").tag(2)
                    Text("Balanced").tag(1)
                    Text("Accurate").tag(0)
                }
                .pickerStyle(.segmented)
                Text("Fast keeps live preview smooth. Accurate gives cleaner hair edges but costs more per frame — fine during export, may stutter preview at retina.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Cursor highlight section

    @ViewBuilder
    private func cursorHighlightSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Cursor halo", isOn: Binding(
                get: { vm.cursorHighlightStyle.enabled },
                set: { var s = vm.cursorHighlightStyle; s.enabled = $0; vm.cursorHighlightStyle = s }
            ))
            .font(.headline)

            if vm.project.cursorLog == nil {
                Text("This recording was made before cursor tracking shipped — the halo needs per-frame cursor positions that aren't in the sidecar. Re-record to enable.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Soft always-on halo that follows the cursor. Useful for drawing attention during a walkthrough. Click ripples and the halo coexist — the ripple fires on top.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Size").frame(width: 58, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.cursorHighlightStyle.radius },
                            set: { var s = vm.cursorHighlightStyle; s.radius = $0; vm.cursorHighlightStyle = s }
                        ),
                        in: 20...200
                    )
                    Text("\(Int(vm.cursorHighlightStyle.radius)) px")
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                }
                HStack {
                    Text("Opacity").frame(width: 58, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.cursorHighlightStyle.opacity },
                            set: { var s = vm.cursorHighlightStyle; s.opacity = $0; vm.cursorHighlightStyle = s }
                        ),
                        in: 0.1...1.0
                    )
                    Text(String(format: "%.0f%%", vm.cursorHighlightStyle.opacity * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 58, alignment: .trailing)
                }
                ColorPicker("Color", selection: Binding(
                    get: {
                        let s = vm.cursorHighlightStyle
                        return Color(red: s.red, green: s.green, blue: s.blue)
                    },
                    set: { newColor in
                        let nsColor = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                        var s = vm.cursorHighlightStyle
                        s.red = nsColor.redComponent
                        s.green = nsColor.greenComponent
                        s.blue = nsColor.blueComponent
                        vm.cursorHighlightStyle = s
                    }
                ))
            }
        }
        .disabled(vm.isExporting)
    }

    // MARK: - Keystrokes overlay section

    @ViewBuilder
    private func keystrokesSection(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Keystrokes").font(.headline)
                Spacer()
                Text("\(vm.keystrokeChips.count) event\(vm.keystrokeChips.count == 1 ? "" : "s")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Toggle("Show keystroke overlay", isOn: Binding(
                get: { vm.keystrokeOverlayStyle.enabled },
                set: { var s = vm.keystrokeOverlayStyle; s.enabled = $0; vm.keystrokeOverlayStyle = s }
            ))

            Text("Renders each captured key press as a floating chip at the bottom of the frame — useful for software walkthroughs. Pulls from the recording's event log; nothing sent to the network.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Include plain keys (letters / symbols)", isOn: Binding(
                get: { vm.keystrokeOverlayStyle.showPlainKeys },
                set: { var s = vm.keystrokeOverlayStyle; s.showPlainKeys = $0; vm.keystrokeOverlayStyle = s }
            ))
            Text("Off by default so only modifier combos (⌘K, ⇧⇥) and special keys (Return, Tab, Esc, arrows) show. Turn on to render every key — can get busy during typing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Size").frame(width: 58, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { vm.keystrokeOverlayStyle.fontSizeFraction },
                        set: { var s = vm.keystrokeOverlayStyle; s.fontSizeFraction = $0; vm.keystrokeOverlayStyle = s }
                    ),
                    in: 0.015...0.05
                )
                Text(String(format: "%.1f%%", vm.keystrokeOverlayStyle.fontSizeFraction * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Bottom").frame(width: 58, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { vm.keystrokeOverlayStyle.bottomInsetFraction },
                        set: { var s = vm.keystrokeOverlayStyle; s.bottomInsetFraction = $0; vm.keystrokeOverlayStyle = s }
                    ),
                    in: 0.02...0.35
                )
                Text(String(format: "%.0f%%", vm.keystrokeOverlayStyle.bottomInsetFraction * 100))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Hold").frame(width: 58, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { vm.keystrokeOverlayStyle.displayDuration },
                        set: { var s = vm.keystrokeOverlayStyle; s.displayDuration = $0; vm.keystrokeOverlayStyle = s }
                    ),
                    in: 0.4...3.0
                )
                Text(String(format: "%.1fs", vm.keystrokeOverlayStyle.displayDuration))
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .disabled(vm.isExporting)
    }

    // MARK: - Cuts section (ripple-delete middle regions)

    @ViewBuilder
    private func cutsSection(vm: EditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cuts").font(.headline)
                if vm.isAutoCutting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if !vm.cutRanges.isEmpty {
                    Button(role: .destructive) {
                        vm.clearCuts()
                    } label: {
                        Text("Clear all")
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 6) {
                Button {
                    vm.autoCutSilences()
                } label: {
                    Label("Auto-cut silences", systemImage: "waveform.slash")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(vm.isAutoCutting)
                .help("Scan the mic track and ripple-delete every pause longer than ~0.8 seconds. Leaves 0.15s buffer on each side so speech tails aren't clipped.")
            }
            if let n = vm.lastAutoCutCount {
                Text(n == 0
                     ? "No cut-worthy silences found."
                     : "Auto-cut added \(n) silence cut\(n == 1 ? "" : "s").")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if vm.cutRanges.isEmpty {
                Text("Select a range on the timeline (⇧I to mark start, scrub, ⇧O to cut) to ripple-delete a section from the output. Or hit Auto-cut silences above to strip long pauses automatically. Keyframes + captions shift to cover each gap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(vm.cutRanges.count) cut\(vm.cutRanges.count == 1 ? "" : "s") — \(cutTotalString(vm: vm)) removed. Output duration: \(outputDurationString(vm: vm)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 4) {
                    ForEach(Array(vm.cutRanges.enumerated()), id: \.offset) { idx, range in
                        HStack(spacing: 6) {
                            Image(systemName: "scissors")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(cutRangeString(range))
                                .font(.caption.monospacedDigit())
                            Spacer()
                            Button {
                                vm.seek(to: range.start)
                            } label: {
                                Image(systemName: "arrow.right.to.line.compact")
                            }
                            .buttonStyle(.plain)
                            .help("Jump to cut start")
                            Button(role: .destructive) {
                                vm.removeCut(at: idx)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .help("Restore this cut")
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
        .disabled(vm.isExporting)
    }

    private func cutTotalString(vm: EditorViewModel) -> String {
        let total = vm.cutRanges.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
        let secs = CMTimeGetSeconds(total)
        return secs.isFinite ? String(format: "%.1fs", secs) : "--"
    }

    private func outputDurationString(vm: EditorViewModel) -> String {
        let secs = CMTimeGetSeconds(vm.trimMap.outputDuration)
        return secs.isFinite ? String(format: "%.1fs", secs) : "--"
    }

    private func cutRangeString(_ range: CMTimeRange) -> String {
        let s = CMTimeGetSeconds(range.start)
        let e = CMTimeGetSeconds(range.end)
        let d = CMTimeGetSeconds(range.duration)
        guard s.isFinite, e.isFinite, d.isFinite else { return "--" }
        return String(format: "%.2fs → %.2fs  (%.2fs)", s, e, d)
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

            Divider().padding(.vertical, 4)

            noiseReductionControls(vm: vm)
        }
        .disabled(vm.isExporting)
    }

    @ViewBuilder
    private func noiseReductionControls(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        HStack {
            Toggle("Noise reduction", isOn: Binding(
                get: { vm.noiseReductionStyle.enabled },
                set: { var s = vm.noiseReductionStyle; s.enabled = $0; vm.noiseReductionStyle = s }
            ))
            .font(.subheadline.weight(.medium))
            Spacer()
            if vm.isCleaningMic {
                ProgressView().controlSize(.small)
            }
        }

        if vm.noiseReductionStyle.enabled {
            HStack {
                Text("Strength").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { vm.noiseReductionStyle.strength },
                    set: { var s = vm.noiseReductionStyle; s.strength = $0; vm.noiseReductionStyle = s }
                )) {
                    ForEach(NoiseReductionStrength.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        Text("Offline high-pass (kills rumble / AC hum) + adaptive noise gate (learns the silence floor and mutes below it). Preview + export both use the cleaned audio. Regenerates whenever you switch strength.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

                // Font family picker — null (system default) plus a
                // curated shortlist of fonts that work well for title
                // cards. Menu-style rather than Picker so the bottom
                // of the list can include a "More Fonts…" action that
                // opens the full system font panel, letting the user
                // reach any font installed on their Mac.
                HStack {
                    Text("Font")
                    Spacer()
                    Menu {
                        ForEach(TitleCardFont.options) { option in
                            Button {
                                card.wrappedValue.fontName = option.familyName
                            } label: {
                                if card.wrappedValue.fontName == option.familyName {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                        Divider()
                        Button("More Fonts…") {
                            // Live callback — every change in the
                            // panel updates the card, so the user
                            // can preview fonts against the other
                            // card settings without closing the
                            // panel first.
                            TitleCardFontPanelBridge.shared.present(
                                currentFamily: card.wrappedValue.fontName
                            ) { newFamily in
                                card.wrappedValue.fontName = newFamily
                            }
                        }
                    } label: {
                        Text(cardFontMenuLabel(for: card.wrappedValue.fontName))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 220)
                }

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

                // Optional background image — when set, aspect-fills
                // over the background colour. Image file is copied
                // into Application Support so the original file can
                // move/rename/delete without breaking the card.
                cardImageControls(card: card)

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

    @ViewBuilder
    private func cardImageControls(card: Binding<TitleCard>) -> some View {
        HStack(spacing: 8) {
            Text("Image")
            if let filename = card.wrappedValue.backgroundImageFilename,
               !filename.isEmpty {
                // Small thumbnail so the user can confirm which image
                // is currently loaded. Built from NSImage → SwiftUI's
                // Image(nsImage:) — cached by AppKit, cheap at this
                // size.
                if let ns = NSImage(contentsOf: TitleCardAssets.url(for: filename)) {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    // File missing — surface that directly so the
                    // user knows the card will render with just the
                    // background colour.
                    Text("(image missing)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                chooseCardImage(for: card)
            } label: {
                Label(
                    card.wrappedValue.backgroundImageFilename == nil ? "Choose…" : "Replace…",
                    systemImage: "photo"
                )
            }
            .controlSize(.small)

            if card.wrappedValue.backgroundImageFilename != nil {
                Button(role: .destructive) {
                    if let old = card.wrappedValue.backgroundImageFilename {
                        TitleCardAssets.remove(filename: old)
                    }
                    card.wrappedValue.backgroundImageFilename = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear the background image — revert to solid colour")
            }
        }
    }

    /// Label shown on the font menu's button. Prefers the curated-
    /// list label when the family matches a known option; otherwise
    /// falls back to the raw family name (which is what `NSFontPanel`
    /// will have fed us). `nil` → "System".
    private func cardFontMenuLabel(for fontName: String?) -> String {
        if let match = TitleCardFont.options.first(where: { $0.familyName == fontName }) {
            return match.label
        }
        return fontName ?? "System"
    }

    /// Open an NSOpenPanel for image selection, copy into the assets
    /// directory, and update the card binding. Previously-stored
    /// image (if any) is removed so we don't accumulate stale files.
    private func chooseCardImage(for card: Binding<TitleCard>) {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let old = card.wrappedValue.backgroundImageFilename {
            TitleCardAssets.remove(filename: old)
        }
        if let stored = TitleCardAssets.store(copyingFrom: url) {
            card.wrappedValue.backgroundImageFilename = stored
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

    /// Full-size transparent overlay used to pick a zoom focus point.
    /// AVPlayerView renders the video with `.resizeAspect`, so the
    /// image occupies a letterboxed sub-rect of the view. We replicate
    /// that aspect-fit math to translate a click into image-pixel
    /// coordinates (bottom-left origin, matching `ZoomKeyframe.target`
    /// and the compositor's convention).
    @ViewBuilder
    private func zoomFocusPlacementOverlay(vm: EditorViewModel) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.opacity(0.001)  // transparent but hit-testable
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        let viewSize = geo.size
                        let img = vm.outputSize
                        guard let fit = Self.aspectFitRect(image: img, in: viewSize) else { return }
                        guard fit.contains(location) else { return }  // click inside letterbox → ignore
                        let localX = location.x - fit.minX
                        let localY = location.y - fit.minY
                        // SwiftUI is top-left origin; target uses
                        // bottom-left origin (Core Image convention).
                        let imgX = localX / fit.width * img.width
                        let imgY = img.height - (localY / fit.height * img.height)
                        if let id = vm.zoomTargetBeingPlaced {
                            vm.setZoomTarget(id: id, imagePixel: CGPoint(x: imgX, y: imgY))
                        }
                    }

                HStack(spacing: 10) {
                    Image(systemName: "scope")
                    Text("Click on the preview to set this zoom's focus point")
                        .font(.callout.weight(.medium))
                    Button("Cancel") { vm.cancelPlacingZoomTarget() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(true)
            }
        }
    }

    /// Webcam drag-to-reposition. The hit-testable catcher is scoped
    /// tightly to the webcam's current display rect so clicks
    /// elsewhere (AVPlayerView's play/pause/timeline controls) still
    /// route through. The rect is safe to pin to the "committed"
    /// position because we don't update `vm.webcamCustomOrigin` until
    /// the drag ends — the webcam doesn't visually move mid-drag, so
    /// neither does the hit area.
    ///
    /// The dashed-outline preview that follows the cursor lives in a
    /// separate, full-preview container with `allowsHitTesting(false)`
    /// so it never steals clicks.
    @ViewBuilder
    private func webcamDragOverlay(vm: EditorViewModel) -> some View {
        GeometryReader { geo in
            if let fit = Self.aspectFitRect(image: vm.outputSize, in: geo.size) {
                WebcamDragLayer(vm: vm, fit: fit)
            }
        }
    }

    /// Stateful container: owns the drag-in-progress target so the
    /// SwiftUI `@State` isn't reset every parent redraw.
    private struct WebcamDragLayer: View {
        let vm: EditorViewModel
        let fit: CGRect

        /// Live target origin in image-pixel space (bottom-left),
        /// only populated while a drag is in progress. When non-nil,
        /// the dashed outline renders at this position instead of the
        /// committed one.
        @State private var dragTarget: CGPoint?
        /// Captured at drag start so we don't chase a moving base.
        @State private var dragStart: CGPoint?

        var body: some View {
            let baseRect = webcamDisplayRect(forImageOrigin: vm.webcamBaseOrigin)

            ZStack(alignment: .topLeading) {
                // Hit-testable catcher, tightly scoped to the webcam's
                // current on-screen rect. Everywhere else in the
                // preview falls through to AVPlayerView's controls.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .frame(width: baseRect.width, height: baseRect.height)
                    .position(x: baseRect.midX, y: baseRect.midY)
                    .gesture(dragGesture)
                    .help("Drag to reposition. Pick a corner in the inspector to reset.")

                // Dashed preview outline — only drawn during drag.
                // Lives in a full-preview container with hit-testing
                // disabled so it never consumes clicks.
                if let target = dragTarget {
                    let outline = webcamDisplayRect(forImageOrigin: target)
                    RoundedRectangle(cornerRadius: outlineCornerRadius(width: outline.width))
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .foregroundStyle(.white)
                        .frame(width: outline.width, height: outline.height)
                        .position(x: outline.midX, y: outline.midY)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
            }
            .allowsHitTesting(true)
            // Outline overlay + shadow need the full preview as their
            // reference frame; apply hit-testing off there in isolation.
            .overlay(alignment: .topLeading) {
                EmptyView().allowsHitTesting(false)
            }
        }

        private var dragGesture: some Gesture {
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    let img = vm.outputSize
                    let sx = fit.width / img.width
                    let sy = fit.height / img.height
                    if dragStart == nil {
                        dragStart = vm.webcamBaseOrigin
                    }
                    guard let start = dragStart else { return }
                    let dx = value.translation.width / sx
                    let dy = -value.translation.height / sy  // flip Y (image bottom-left)
                    let d = vm.webcamDiameter
                    let maxX = max(0, img.width - d)
                    let maxY = max(0, img.height - d)
                    dragTarget = CGPoint(
                        x: min(max(0, start.x + dx), maxX),
                        y: min(max(0, start.y + dy), maxY)
                    )
                }
                .onEnded { _ in
                    // Single compositor update = single seek, no jitter.
                    if let target = dragTarget {
                        vm.webcamCustomOrigin = target
                    }
                    dragTarget = nil
                    dragStart = nil
                }
        }

        /// Convert an image-pixel origin (bottom-left) into the
        /// display-space rect that represents the webcam at that
        /// origin, using the current aspect-fit mapping.
        private func webcamDisplayRect(forImageOrigin origin: CGPoint) -> CGRect {
            let img = vm.outputSize
            let d = vm.webcamDiameter
            let sx = fit.width / img.width
            let sy = fit.height / img.height
            let x = fit.minX + origin.x * sx
            // Y flip: image origin is bottom-left, SwiftUI is top-left.
            let y = fit.minY + (img.height - origin.y - d) * sy
            return CGRect(x: x, y: y, width: d * sx, height: d * sy)
        }

        private func outlineCornerRadius(width: CGFloat) -> CGFloat {
            switch vm.webcamShape {
            case .circle:        return width / 2
            case .roundedSquare: return width * 0.18
            case .none:          return 0
            }
        }
    }

    /// Compute the aspect-fit display rect for an image of the given
    /// pixel size inside a view of `viewSize`. Returns nil for
    /// degenerate inputs.
    private static func aspectFitRect(image: CGSize, in viewSize: CGSize) -> CGRect? {
        guard image.width > 0, image.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return nil }
        let imgAspect = image.width / image.height
        let viewAspect = viewSize.width / viewSize.height
        if viewAspect > imgAspect {
            // Pillarbox — image height = view height; width constrained.
            let w = viewSize.height * imgAspect
            let x = (viewSize.width - w) / 2
            return CGRect(x: x, y: 0, width: w, height: viewSize.height)
        } else {
            // Letterbox — image width = view width; height constrained.
            let h = viewSize.width / imgAspect
            let y = (viewSize.height - h) / 2
            return CGRect(x: 0, y: y, width: viewSize.width, height: h)
        }
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
            if let sel = viewModel.selectionRange {
                let a = xForTime(sel.start, width: width)
                let b = xForTime(sel.end, width: width)
                Rectangle()
                    .fill(Color.orange.opacity(0.4))
                    .frame(width: max(0, b - a), height: trackHeight)
                    .offset(x: a)
                    .allowsHitTesting(false)
            }

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

            Button {
                viewModel.cutSelection()
            } label: {
                Label("Cut", systemImage: "scissors")
            }
            .keyboardShortcut("o", modifiers: .shift)
            .disabled(viewModel.selectionRange == nil)
            .help("Delete selected range (⇧O) — ripples timeline + keyframes")

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

// MARK: - Caption edit list

/// Expandable inline editor for the full transcription. Shown inside
/// the Captions inspector section when a transcription exists. Lifted
/// to its own `View` struct so it can own the `@State` for expansion +
/// per-row text-field buffers without forcing the enclosing editor to
/// re-render the entire inspector on every keystroke.
///
/// Row layout: one horizontal row per line — timestamp pill (click to
/// jump playhead), editable text field, "set-to-playhead" buttons for
/// start/end, trash. Text edits + timing nudges route through the
/// viewModel's coalesced-undo helpers so a burst of edits collapses to
/// one undo entry.
private struct CaptionEditList: View {
    let vm: EditorViewModel
    let lines: [TranscriptionLine]
    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(spacing: 4) {
                ForEach(lines) { line in
                    CaptionEditRow(vm: vm, line: line)
                        .id(line.id)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text("Edit lines").font(.subheadline.weight(.medium))
                Text("\(lines.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        // Expand automatically when a timeline caption pill is tapped
        // — the inspector's ScrollViewReader scrolls to the row, but
        // the row is useless if this disclosure is still collapsed.
        .onChange(of: vm.focusedCaptionLineId) { _, newValue in
            if newValue != nil && !isExpanded {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded = true
                }
            }
        }
    }
}

private struct CaptionEditRow: View {
    let vm: EditorViewModel
    let line: TranscriptionLine

    // Local buffer so typing feels immediate — we push to the view
    // model onChange but don't round-trip through the persisted log on
    // every keystroke. Seeded fresh each time `line.text` changes from
    // outside (undo/redo, regeneration, etc).
    @State private var textBuffer: String = ""
    @State private var seeded: Bool = false

    /// Focus driver — SwiftUI fills the field editor automatically when
    /// this flips true, scrolling into view and selecting all text.
    /// Triggered by a timeline pill click via `focusedCaptionLineId`.
    @FocusState private var isTextFocused: Bool

    var body: some View {
        // Slight accent tint when this row is the one the user just
        // clicked on in the timeline lane — helps correlate which pill
        // → which row at a glance.
        let isFocused = vm.focusedCaptionLineId == line.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    vm.seek(to: CMTime(seconds: line.startSeconds, preferredTimescale: 600))
                } label: {
                    Text(timestampString(line.startSeconds))
                        .font(.caption2.monospacedDigit())
                }
                .buttonStyle(.plain)
                .help("Jump playhead to this caption's start")

                TextField("caption text", text: $textBuffer)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isTextFocused)
                    .onChange(of: textBuffer) { _, new in
                        // Skip the initial seed write so undo stays clean.
                        guard seeded, new != line.text else { return }
                        vm.updateCaptionLineText(id: line.id, to: new)
                    }

                Button(role: .destructive) {
                    vm.deleteCaptionLine(id: line.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Delete this caption line")
            }
            HStack(spacing: 6) {
                Text("Start")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                secondsField(
                    value: line.startSeconds,
                    commit: { newStart in
                        vm.updateCaptionLineTiming(id: line.id, start: newStart, end: line.endSeconds)
                    }
                )
                Button {
                    vm.updateCaptionLineTiming(
                        id: line.id,
                        start: CMTimeGetSeconds(vm.currentTime),
                        end: line.endSeconds
                    )
                } label: {
                    Image(systemName: "arrow.down.to.line.compact")
                }
                .buttonStyle(.plain)
                .help("Snap start to playhead")

                Text("End")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                secondsField(
                    value: line.endSeconds,
                    commit: { newEnd in
                        vm.updateCaptionLineTiming(id: line.id, start: line.startSeconds, end: newEnd)
                    }
                )
                Button {
                    vm.updateCaptionLineTiming(
                        id: line.id,
                        start: line.startSeconds,
                        end: CMTimeGetSeconds(vm.currentTime)
                    )
                } label: {
                    Image(systemName: "arrow.up.to.line.compact")
                }
                .buttonStyle(.plain)
                .help("Snap end to playhead")

                Spacer()
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            (isFocused ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onAppear {
            // Seed the text buffer on first appearance and whenever the
            // backing line's text shifts from outside this row (undo).
            if !seeded || textBuffer != line.text {
                textBuffer = line.text
                seeded = true
            }
            // If the app just launched with a pre-existing focused id
            // matching this row, grab focus on appearance. The onChange
            // below handles the normal "user clicks a pill" path.
            if isFocused { isTextFocused = true }
        }
        .onChange(of: line.text) { _, new in
            if textBuffer != new {
                textBuffer = new
            }
        }
        .onChange(of: vm.focusedCaptionLineId) { _, newValue in
            // Only this row's matching id should take focus — avoids a
            // broadcast that would make every row grab focus on every
            // change (and thrash the field editor).
            if newValue == line.id {
                // Defer so the DisclosureGroup has finished animating
                // open and the TextField is actually attached.
                DispatchQueue.main.async {
                    isTextFocused = true
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func secondsField(
        value: TimeInterval,
        commit: @escaping (TimeInterval) -> Void
    ) -> some View {
        TextField(
            "",
            value: Binding<TimeInterval>(
                get: { value },
                set: { commit($0) }
            ),
            format: .number.precision(.fractionLength(2))
        )
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(width: 58)
        .multilineTextAlignment(.trailing)
    }

    private func timestampString(_ s: TimeInterval) -> String {
        guard s.isFinite else { return "--:--.-" }
        let totalMs = Int(max(0, s) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        let m = totalSec / 60
        let sec = totalSec % 60
        return String(format: "%02d:%02d.%d", m, sec, tenths)
    }
}
