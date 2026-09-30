import SwiftUI
import AppKit

/// Inspector: the always-on cursor highlight halo.
struct CursorHighlightSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
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
}
