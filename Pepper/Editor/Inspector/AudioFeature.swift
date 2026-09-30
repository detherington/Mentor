import SwiftUI

/// Clean up audio row: noise cleanup for the voice, and the volume of
/// each sound source.
struct AudioFeature: View {
    @Bindable var vm: EditorViewModel

    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.noiseReductionStyle.enabled },
            set: { var s = vm.noiseReductionStyle; s.enabled = $0; vm.noiseReductionStyle = s }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        guard vm.noiseReductionStyle.enabled else { return "Off" }
        if vm.isCleaningMic { return "Cleaning up your voice…" }
        return vm.noiseReductionStyle.strength == .strong ? "Strong noise cleanup" : "Light noise cleanup"
    }

    var body: some View {
        Note("Takes out hum and background noise behind your voice.")
        if vm.isCleaningMic {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Note("Cleaning up your voice…")
            }
        }
        FieldLabel("How much")
        ChoiceStrip(
            label: "How much cleanup",
            options: [("Light", NoiseReductionStrength.light), ("Strong", .strong)],
            selection: Binding(
                get: { vm.noiseReductionStyle.strength },
                set: { var s = vm.noiseReductionStyle; s.strength = $0; s.enabled = true; vm.noiseReductionStyle = s }
            )
        )
        Note("Strong suits noisy rooms but can clip the ends of quiet words.")

        Divider()

        HStack {
            RowHeading("Volume")
            Spacer()
            Button("Reset") { vm.audioMixVolumes = .unity }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        volume("Your voice", \.mic)
        volume("Sound from your Mac", \.system)
        if vm.hasSoundboardTrack {
            volume("Soundboard", \.soundboard)
        }
        Note("The middle of each slider is how it was recorded.")
    }

    private func volume(_ label: String, _ track: WritableKeyPath<AudioMixBuilder.Volumes, Float>) -> some View {
        PlainSlider(
            label: label,
            value: Binding(
                get: { Double(vm.audioMixVolumes[keyPath: track]) },
                set: { var v = vm.audioMixVolumes; v[keyPath: track] = Float($0); vm.audioMixVolumes = v }
            ),
            range: 0...2, low: "Silent", high: "Louder"
        )
    }
}
