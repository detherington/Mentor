import SwiftUI
import AppKit

/// Cursor & clicks row: click ripples and the cursor highlight, which
/// used to be two sections in different parts of the panel.
struct CursorFeature: View {
    @Bindable var vm: EditorViewModel

    /// On when either effect is. Off turns both off; on brings the
    /// ripples back (the highlight is the rarer choice).
    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.cursorRipplesEnabled || vm.cursorHighlightStyle.enabled },
            set: { on in
                if on {
                    vm.cursorRipplesEnabled = true
                } else {
                    vm.cursorRipplesEnabled = false
                    var s = vm.cursorHighlightStyle
                    s.enabled = false
                    vm.cursorHighlightStyle = s
                }
            }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        switch (vm.cursorRipplesEnabled, vm.cursorHighlightStyle.enabled) {
        case (true, true):   return "Ripples and a highlight"
        case (true, false):  return "A ripple on each click"
        case (false, true):  return "Cursor highlight"
        case (false, false): return "Off"
        }
    }

    var body: some View {
        Toggle("Ripple on each click", isOn: $vm.cursorRipplesEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12.5))
        // Ripples only exist for clicks inside the recorded area, so an
        // empty list isn't always "no clicks".
        if vm.loggedClickCount == 0 {
            Note("No clicks were recorded, so there's nothing to ripple.")
        } else if vm.cursorRipples.isEmpty {
            Note("None of your clicks landed inside the recorded area.")
        }

        Toggle("Highlight the cursor", isOn: Binding(
            get: { vm.cursorHighlightStyle.enabled },
            set: { var s = vm.cursorHighlightStyle; s.enabled = $0; vm.cursorHighlightStyle = s }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12.5))
        .disabled(vm.project.cursorLog == nil)

        if vm.project.cursorLog == nil {
            Note("This recording is too old for the cursor highlight. Record again to use it.")
        } else if vm.cursorHighlightStyle.enabled {
            PlainSlider(
                label: "Highlight size",
                value: Binding(
                    get: { vm.cursorHighlightStyle.radius },
                    set: { var s = vm.cursorHighlightStyle; s.radius = $0; vm.cursorHighlightStyle = s }
                ),
                range: 20...200, low: "Small", high: "Large"
            )
            PlainSlider(
                label: "Highlight strength",
                value: Binding(
                    get: { vm.cursorHighlightStyle.opacity },
                    set: { var s = vm.cursorHighlightStyle; s.opacity = $0; vm.cursorHighlightStyle = s }
                ),
                range: 0.1...1.0, low: "Faint", high: "Bold"
            )
            ColorPicker("Highlight color", selection: Binding(
                get: {
                    let s = vm.cursorHighlightStyle
                    return Color(red: s.red, green: s.green, blue: s.blue)
                },
                set: { newColor in
                    let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                    var s = vm.cursorHighlightStyle
                    s.red = ns.redComponent
                    s.green = ns.greenComponent
                    s.blue = ns.blueComponent
                    vm.cursorHighlightStyle = s
                }
            ))
            .font(.system(size: 12.5))
        }
    }
}
