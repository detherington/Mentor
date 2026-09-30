import SwiftUI
import AVFoundation

/// Inspector: talking-head moments (webcam grows to fill the frame).
struct TalkingHeadSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Talking head").font(.headline)
                Spacer()
                PlayheadGatedButton(
                    title: "Add at playhead",
                    help: "Add a talking-head moment at the playhead.",
                    isEnabled: { vm.canAddTalkingHeadAtPlayhead },
                    action: { vm.addTalkingHeadAtPlayhead() }
                )
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
                    Text(TimelineMath.timeString(kf.startTime))
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
}
