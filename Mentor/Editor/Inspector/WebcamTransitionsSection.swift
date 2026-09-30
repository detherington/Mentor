import SwiftUI

/// Inspector: webcam fade-in / fade-out at the recording's start and end.
struct WebcamTransitionsSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Webcam transitions").font(.headline)

            HStack {
                Text("Fade in")
                Slider(
                    value: Binding(
                        get: { vm.webcamTransitions.fadeIn },
                        set: { vm.webcamTransitions = WebcamTransitions(fadeIn: $0, fadeOut: vm.webcamTransitions.fadeOut) }
                    ),
                    in: 0...3
                )
                Text(String(format: "%.1fs", vm.webcamTransitions.fadeIn))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            HStack {
                Text("Fade out")
                Slider(
                    value: Binding(
                        get: { vm.webcamTransitions.fadeOut },
                        set: { vm.webcamTransitions = WebcamTransitions(fadeIn: vm.webcamTransitions.fadeIn, fadeOut: $0) }
                    ),
                    in: 0...3
                )
                Text(String(format: "%.1fs", vm.webcamTransitions.fadeOut))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text("Webcam smoothly appears at the start and disappears at the end. Set to 0 to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(vm.isExporting)
    }
}
