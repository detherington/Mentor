import SwiftUI
import AVFoundation

/// Inspector: smart zoom — auto-generated and manual zoom keyframes.
struct SmartZoomSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Smart zoom", isOn: $vm.zoomEnabled)
                    .font(.headline)
                Spacer()
                PlayheadGatedButton(
                    title: "Add",
                    help: "Add a manual zoom keyframe at the playhead, targeting the centre of the canvas. Uses your current Amount setting for the peak scale.",
                    isEnabled: { vm.canAddZoomAtPlayhead },
                    action: { vm.addZoomAtPlayhead() }
                )
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
                    // Label above rather than beside: side by side, this row
                    // needed ~300 pt and pushed the whole inspector wider
                    // than its column (which then clipped both edges).
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sensitivity")
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
                    Text(TimelineMath.timeString(kf.startTime))
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

    /// Explain *why* there are zero zoom keyframes. The likely culprit
    /// changes with the source kind + how the recording was made, and a
    /// generic "no clicks detected" message was sending users to check
    /// permissions that were already granted.
    private func smartZoomHint(vm: EditorViewModel) -> String {
        if !vm.zoomKeyframes.isEmpty {
            let n = vm.zoomKeyframes.count
            return "\(n) auto-generated zoom moment\(n == 1 ? "" : "s"). Click the purple pills in the timeline to jump to one."
        }
        let clicks = vm.loggedClickCount
        let kind = vm.project.metadata.source.kind
        let hasFrame = vm.project.metadata.source.windowFrameWidth != nil
        if clicks == 0 {
            return "No clicks were logged during this recording. Smart zoom needs the global Accessibility permission so Pepper can record click positions."
        }
        if kind == "window" && !hasFrame {
            return "\(clicks) clicks were logged, but this recording was made before window-position tracking was added. Re-record (or capture a Display) to get smart zoom."
        }
        return "\(clicks) clicks logged but none fell inside the captured area — smart zoom found nothing to focus on."
    }
}
