import SwiftUI
import AVFoundation

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
struct CaptionEditList: View {
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
                Text("Edit caption text").font(.system(size: 12.5, weight: .medium))
                Text("\(lines.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        // Opened from a timeline caption pill: the row (and this list)
        // appears after the tap, so expand on arrival too.
        .onAppear {
            if vm.focusedCaptionLineId != nil { isExpanded = true }
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

struct CaptionEditRow: View {
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
