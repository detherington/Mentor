import SwiftUI

/// Inspector: keystroke overlay chips.
struct KeystrokesSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
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
}
