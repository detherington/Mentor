import SwiftUI
import AVFoundation

/// Smart zoom row: how close and how long for every zoom, the zoom
/// picked on the timeline on its own, and (tucked away) regenerating
/// them from the clicks.
struct ZoomFeature: View {
    @Bindable var vm: EditorViewModel

    /// "How close" presets, as peak scale.
    private static let closeness: [(String, Double)] = [("Subtle", 1.25), ("Medium", 1.5), ("Close", 1.85)]

    static func status(_ vm: EditorViewModel) -> String {
        guard vm.zoomEnabled else { return "Off" }
        let n = vm.zoomKeyframes.count
        if n > 0 { return "\(n) zoom\(n == 1 ? "" : "s"), following your clicks" }
        return vm.loggedClickCount == 0 ? "No clicks were recorded" : "No zooms yet"
    }

    var body: some View {
        if let hint = noZoomsHint {
            Note(hint)
        }

        FieldLabel("How close")
        ChoiceStrip(
            label: "How close",
            options: Self.closeness.map { (label: $0.0, value: $0.0) },
            selection: Binding(
                get: { InspectorFormat.nearest(Double(vm.zoomTuning.scale), in: Self.closeness.map { ($0.0, $0.1) }) },
                set: { name in
                    if let preset = Self.closeness.first(where: { $0.0 == name }) {
                        vm.setScaleForAllZooms(CGFloat(preset.1))
                    }
                }
            )
        )

        PlainSlider(
            label: "How long it stays zoomed",
            value: Binding(get: { vm.zoomTuning.holdSeconds }, set: { vm.setHoldForAllZooms($0) }),
            range: 0.1...2.5, low: "Quick", high: "Lingers"
        )

        if let id = vm.selectedZoomID, let kf = vm.zoomKeyframes.first(where: { $0.id == id }) {
            SelectedZoomEditor(vm: vm, kf: kf)
        }

        Note("Zooms show in purple on the timeline. Drag one to move it, drag its right edge to make it longer, or click it to change just that one.")

        PlayheadGatedButton(
            title: "Add a zoom at the playhead",
            help: "Add a zoom where the playhead is, toward the middle of the screen. Set its focus point afterwards.",
            isEnabled: { vm.canAddZoomAtPlayhead },
            action: { vm.addZoomAtPlayhead() }
        )

        MoreOptions {
            FieldLabel("How many zooms")
            ChoiceStrip(
                label: "How many zooms",
                options: [("Fewer", ZoomTuning.Sensitivity.low), ("Balanced", .medium), ("More", .high)],
                selection: Binding(
                    get: { vm.zoomTuning.sensitivity },
                    set: { var t = vm.zoomTuning; t.sensitivity = $0; vm.zoomTuning = t }
                )
            )
            Button {
                vm.regenerateZoomFromClicks()
            } label: {
                Label("Redo zooms from my clicks", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .disabled(vm.loggedClickCount == 0)
            Note("Replaces every zoom, including ones you moved or added.")
        }
    }

    /// Why there are no zooms, when that's not obvious.
    private var noZoomsHint: String? {
        guard vm.zoomKeyframes.isEmpty else { return nil }
        if vm.loggedClickCount == 0 {
            return "Pepper didn't see any clicks in this recording. It needs Accessibility turned on (Settings › Setup) to follow your clicks in future recordings. You can still add zooms by hand."
        }
        let kind = vm.project.metadata.source.kind
        if kind == "window" && vm.project.metadata.source.windowFrameWidth == nil {
            return "This window recording is too old for smart zoom. Record again to get zooms on your clicks."
        }
        return "None of your clicks landed inside the recorded area."
    }
}

/// The zoom picked on the timeline: its own closeness, length and focus.
private struct SelectedZoomEditor: View {
    @Bindable var vm: EditorViewModel
    let kf: ZoomKeyframe

    var body: some View {
        let hold = CMTimeGetSeconds(CMTimeSubtract(kf.holdEndTime, CMTimeAdd(kf.startTime, kf.inDuration)))
        let isPlacing = vm.zoomTargetBeingPlaced == kf.id

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Zoom at \(InspectorFormat.time(kf.startTime))").brandKicker(10.5, color: Brand.violetInk)
                Spacer()
                Button {
                    vm.selectedZoomID = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop editing this zoom")
            }
            PlainSlider(
                label: "How close",
                value: Binding(get: { Double(kf.scale) }, set: { vm.setZoomKeyframeScale(id: kf.id, scale: CGFloat($0)) }),
                range: 1.1...2.5, low: "Subtle", high: "Close"
            )
            PlainSlider(
                label: "Stays zoomed for \(InspectorFormat.seconds(hold))",
                value: Binding(
                    get: { max(0.25, hold) },
                    set: { vm.setZoomKeyframeHold(id: kf.id, hold: CMTime(seconds: $0, preferredTimescale: 600)) }
                ),
                range: 0.25...10, low: "Brief", high: "Long"
            )
            HStack(spacing: 8) {
                Button {
                    if isPlacing {
                        vm.cancelPlacingZoomTarget()
                    } else {
                        vm.beginPlacingZoomTarget(id: kf.id)
                    }
                } label: {
                    Label(isPlacing ? "Cancel" : "Pick where it zooms", systemImage: isPlacing ? "xmark.circle" : "scope")
                }
                .controlSize(.small)
                .help("Then click the spot in the preview")
                Spacer()
                Button(role: .destructive) {
                    vm.removeZoomKeyframe(id: kf.id)
                } label: {
                    Text("Delete")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        // Violet like its pill on the timeline, so the two read as one.
        .background(Brand.violetTint, in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                .strokeBorder(Brand.violet.opacity(0.45))
        )
    }
}
