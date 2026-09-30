import SwiftUI

/// Inspector: per-track volumes and mic noise reduction.
struct AudioMixSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        let hasSoundboard = vm.hasSoundboardTrack

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio mix").font(.headline)
                Spacer()
                Button {
                    vm.audioMixVolumes = .unity
                } label: {
                    Text("Reset")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Set all tracks to unit gain")
            }

            mixSlider(
                label: "Mic",
                systemImage: "mic.fill",
                value: Binding(
                    get: { Double(vm.audioMixVolumes.mic) },
                    set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                        mic: Float(v),
                        system: vm.audioMixVolumes.system,
                        soundboard: vm.audioMixVolumes.soundboard
                    )}
                )
            )
            mixSlider(
                label: "System",
                systemImage: "speaker.wave.2.fill",
                value: Binding(
                    get: { Double(vm.audioMixVolumes.system) },
                    set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                        mic: vm.audioMixVolumes.mic,
                        system: Float(v),
                        soundboard: vm.audioMixVolumes.soundboard
                    )}
                )
            )
            if hasSoundboard {
                mixSlider(
                    label: "Soundboard",
                    systemImage: "music.note.list",
                    value: Binding(
                        get: { Double(vm.audioMixVolumes.soundboard) },
                        set: { v in vm.audioMixVolumes = AudioMixBuilder.Volumes(
                            mic: vm.audioMixVolumes.mic,
                            system: vm.audioMixVolumes.system,
                            soundboard: Float(v)
                        )}
                    )
                )
            }

            Text("Balances the three audio sources in the preview and the exported MP4. 0 mutes, 1 is original volume, values above 1 amplify (watch for clipping).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            noiseReductionControls(vm: vm)
        }
        .disabled(vm.isExporting)
    }

    @ViewBuilder
    private func noiseReductionControls(vm: EditorViewModel) -> some View {
        @Bindable var vm = vm
        HStack {
            Toggle("Noise reduction", isOn: Binding(
                get: { vm.noiseReductionStyle.enabled },
                set: { var s = vm.noiseReductionStyle; s.enabled = $0; vm.noiseReductionStyle = s }
            ))
            .font(.subheadline.weight(.medium))
            Spacer()
            if vm.isCleaningMic {
                ProgressView().controlSize(.small)
            }
        }

        if vm.noiseReductionStyle.enabled {
            HStack {
                Text("Strength").frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(
                    get: { vm.noiseReductionStyle.strength },
                    set: { var s = vm.noiseReductionStyle; s.strength = $0; vm.noiseReductionStyle = s }
                )) {
                    ForEach(NoiseReductionStrength.allCases) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        Text("Offline high-pass (kills rumble / AC hum) + adaptive noise gate (learns the silence floor and mutes below it). Preview + export both use the cleaned audio. Regenerates whenever you switch strength.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func mixSlider(label: String, systemImage: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...2)
            Text(String(format: "%.2f×", value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}
