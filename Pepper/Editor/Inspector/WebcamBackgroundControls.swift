import SwiftUI
import AppKit

/// Inspector: webcam background effect (blur, colour, transparent).
struct WebcamBackgroundControls: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A menu, not a segmented control — see the Shape picker.
            Picker("Background", selection: Binding(
                get: { vm.webcamBackgroundStyle.mode },
                set: { var s = vm.webcamBackgroundStyle; s.mode = $0; vm.webcamBackgroundStyle = s }
            )) {
                ForEach(WebcamBackgroundMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.menu)

            switch vm.webcamBackgroundStyle.mode {
            case .off:
                Text("Raw webcam passes through to the overlay. No segmentation cost.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .blur:
                HStack {
                    Text("Strength").frame(width: 70, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.webcamBackgroundStyle.blurRadius },
                            set: { var s = vm.webcamBackgroundStyle; s.blurRadius = $0; vm.webcamBackgroundStyle = s }
                        ),
                        in: 4...40
                    )
                    Text("\(Int(vm.webcamBackgroundStyle.blurRadius))")
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                }
            case .color:
                ColorPicker("Color", selection: Binding(
                    get: {
                        let s = vm.webcamBackgroundStyle
                        return Color(red: s.red, green: s.green, blue: s.blue)
                    },
                    set: { newColor in
                        let nsColor = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                        var s = vm.webcamBackgroundStyle
                        s.red = nsColor.redComponent
                        s.green = nsColor.greenComponent
                        s.blue = nsColor.blueComponent
                        vm.webcamBackgroundStyle = s
                    }
                ))
            case .transparent:
                Text("Background is fully transparent — the screen recording shows through the webcam's shape. Great for a free-floating talking-head look.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.webcamBackgroundStyle.mode != .off {
                Picker("Quality", selection: Binding(
                    get: { vm.webcamBackgroundStyle.qualityLevel },
                    set: { var s = vm.webcamBackgroundStyle; s.qualityLevel = $0; vm.webcamBackgroundStyle = s }
                )) {
                    Text("Fast").tag(2)
                    Text("Balanced").tag(1)
                    Text("Accurate").tag(0)
                }
                .pickerStyle(.menu)
                Text("Fast keeps live preview smooth. Accurate gives cleaner hair edges but costs more per frame — fine during export, may stutter preview at retina.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }
}
