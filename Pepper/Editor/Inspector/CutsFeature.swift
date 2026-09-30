import SwiftUI
import AVFoundation

/// Cuts row: take out long pauses automatically, see and undo each cut,
/// and how to cut or trim by hand. No switch — cuts are a list, not a
/// setting.
struct CutsFeature: View {
    @Bindable var vm: EditorViewModel

    static func status(_ vm: EditorViewModel) -> String {
        if vm.isAutoCutting { return "Finding long pauses…" }
        let n = vm.cutRanges.count
        guard n > 0 else { return "Nothing cut yet" }
        let saved = vm.cutRanges.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        return "\(n) cut\(n == 1 ? "" : "s"), \(InspectorFormat.seconds(saved)) shorter"
    }

    var body: some View {
        Note("Take out long pauses automatically, or cut any part yourself.")

        Button {
            vm.autoCutSilences()
        } label: {
            HStack(spacing: 6) {
                if vm.isAutoCutting { ProgressView().controlSize(.small) }
                Text(vm.isAutoCutting ? "Finding pauses…" : "Cut long pauses")
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(vm.isAutoCutting)

        if let n = vm.lastAutoCutCount {
            Note(n == 0 ? "No long pauses found." : "Cut \(n) long pause\(n == 1 ? "" : "s").")
        }

        if !vm.cutRanges.isEmpty {
            VStack(spacing: 4) {
                ForEach(Array(vm.cutRanges.enumerated()), id: \.offset) { idx, range in
                    HStack(spacing: 6) {
                        Button {
                            vm.seek(to: range.start)
                        } label: {
                            Text("\(InspectorFormat.time(range.start)) – \(InspectorFormat.time(range.end))")
                                .font(.system(size: 12).monospacedDigit())
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this cut")
                        Spacer()
                        Button("Put back") { vm.removeCut(at: idx) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Brand.chip, in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous))
                }
            }
            Button("Put everything back") { vm.clearCuts() }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }

        Divider()

        RowHeading("Cut or trim by hand")
        Note("To cut a part: move to where it starts and press Mark (⇧I) in the timeline controls, move to where it ends, then press Cut (⇧O). To trim the start or end, drag the handles at either end of the timeline.")
    }
}
