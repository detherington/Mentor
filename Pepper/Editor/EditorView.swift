import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// The recording editor: live preview composited from the raw screen +
/// webcam tracks, an inspector for every overlay, and the timeline.
struct EditorView: View {
    @State private var viewModel: EditorViewModel
    @State private var showOrbisSheet = false
    @State private var showRecordingInfo = false

    /// The window controller owns the view model (quit + close handling
    /// need to reach it); the view just holds it for SwiftUI.
    init(viewModel: EditorViewModel) {
        _viewModel = State(wrappedValue: viewModel)
    }

    var body: some View {
        @Bindable var vm = viewModel

        return content(vm: vm)
            .toolbar { toolbarContent(vm: vm) }
            .sheet(isPresented: Binding(
                get: { vm.isExporting || vm.exportError != nil },
                set: { if !$0 { vm.exportError = nil } }
            )) {
                ExportSheet(viewModel: vm)
            }
            .sheet(isPresented: $showOrbisSheet) {
                OrbisExportSheet(vm: vm) {
                    showOrbisSheet = false
                }
            }
            .onChange(of: vm.pendingMenuCommand) { _, command in
                guard let command else { return }
                vm.pendingMenuCommand = nil
                switch command {
                case .export:      runExportSavePanel(viewModel: vm)
                case .sendToOrbis: showOrbisSheet = true
                }
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

            EditorInspector(vm: vm)
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 420)
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
            // Muesli's ground strip, like its chat bar.
            .background(Brand.ground)
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

    // MARK: - Toolbar

    /// Export and the recording's details, in the window toolbar. They
    /// used to sit at the top (details) and very bottom (export) of the
    /// inspector, where export was the hardest thing to find.
    @ToolbarContentBuilder
    private func toolbarContent(vm: EditorViewModel) -> some ToolbarContent {
        let unavailable = vm.isExporting || vm.isLoading || vm.loadError != nil
        ToolbarItem(placement: .primaryAction) {
            Button {
                showRecordingInfo.toggle()
            } label: {
                Label("Recording details", systemImage: "info.circle")
            }
            .help("Recording details")
            .popover(isPresented: $showRecordingInfo, arrowEdge: .bottom) {
                recordingInfo(vm: vm)
            }
        }
        if OrbisAccount.shared.isConnected {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showOrbisSheet = true
                } label: {
                    Label("Send to Orbis", systemImage: "arrow.up.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Upload this video to your Orbis library")
                .disabled(unavailable)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                runExportSavePanel(viewModel: vm)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .help("Save the edited video as an MP4")
            .disabled(unavailable)
        }
    }

    private func recordingInfo(vm: EditorViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recording").brandKicker(10.5)
            LabeledRow("Recorded", value: vm.project.metadata.startDate.formatted(date: .abbreviated, time: .shortened))
            LabeledRow("Source", value: vm.project.metadata.source.kind.capitalized)
            LabeledRow("Screen", value: dimensions(vm.project.metadata.screenPixelSize))
            LabeledRow("Webcam", value: dimensions(vm.project.metadata.webcamPixelSize))
            if let events = vm.project.eventLog?.events {
                LabeledRow("Clicks & keys", value: "\(events.count)")
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func dimensions(_ size: RecordingMetadata.CGSizeCodable) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: - Export save panel

    @MainActor
    private func runExportSavePanel(viewModel vm: EditorViewModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = vm.suggestedExportFilename
        panel.canCreateDirectories = true
        panel.directoryURL = vm.suggestedExportDirectory
        panel.title = "Export Video"
        panel.message = "Save your edited video as an MP4."
        panel.accessoryView = ExportOptionsAccessory.make(viewModel: vm)

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
                    .simultaneousGesture(TapGesture().onEnded { vm.openInspectorFeature = .webcam })
                    .help("Drag to move the webcam. Click it to change its look.")

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
        }

        private var dragGesture: some Gesture {
            DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { value in
                    let img = vm.outputSize
                    let sx = fit.width / img.width
                    let sy = fit.height / img.height
                    if dragStart == nil {
                        dragStart = vm.webcamBaseOrigin
                        // Moving the webcam: show its settings.
                        vm.openInspectorFeature = .webcam
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
