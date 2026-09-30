import SwiftUI
import AVFoundation

/// Inspector: interior cuts (ripple-delete middle regions).
struct CutsSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
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
}
