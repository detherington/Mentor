import SwiftUI

/// Inspector: on-device captions — generate, style, edit.
struct CaptionsSection: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Captions").font(.headline)
                Spacer()
                if vm.isTranscribing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let log = vm.transcription {
                Toggle("Show captions", isOn: Binding(
                    get: { vm.captionStyle.enabled },
                    set: { var s = vm.captionStyle; s.enabled = $0; vm.captionStyle = s }
                ))

                Text("\(log.lines.count) line\(log.lines.count == 1 ? "" : "s") transcribed on-device (\(log.locale)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Size")
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.captionStyle.fontSizeFraction },
                            set: { var s = vm.captionStyle; s.fontSizeFraction = $0; vm.captionStyle = s }
                        ),
                        in: 0.025...0.08
                    )
                    Text(String(format: "%.1f%%", vm.captionStyle.fontSizeFraction * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Bottom")
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { vm.captionStyle.bottomInsetFraction },
                            set: { var s = vm.captionStyle; s.bottomInsetFraction = $0; vm.captionStyle = s }
                        ),
                        in: 0.01...0.3
                    )
                    Text(String(format: "%.0f%%", vm.captionStyle.bottomInsetFraction * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                }

                HStack(spacing: 6) {
                    Button {
                        vm.generateCaptions()
                    } label: {
                        Label("Regenerate", systemImage: "waveform")
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)

                    Button(role: .destructive) {
                        vm.clearCaptions()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)
                }

                // Per-line edit list. Collapsed by default — most
                // transcriptions are a dozen-plus lines and an always-
                // open list would dwarf every other inspector section.
                CaptionEditList(vm: vm, lines: log.lines)

                Toggle("Export .srt alongside MP4", isOn: $vm.exportSRTSidecar)
                    .help("Writes a subtitle sidecar file next to the exported MP4. YouTube / Premiere / Final Cut / DaVinci all accept .srt. Timestamps reflect your trim + cuts.")
            } else {
                Text("Transcribe your narration on-device to burn subtitles into the exported MP4. First run prompts for Speech Recognition permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    vm.generateCaptions()
                } label: {
                    Label("Generate from mic", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .disabled(vm.isTranscribing)
            }

            if let err = vm.transcriptionError {
                Text(err.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                // macOS 26 has a quirk where on-device
                // SFSpeechURLRecognitionRequest can return empty even
                // when Dictation works. Offer an explicit cloud retry.
                if vm.transcriptionErrorIsNoSpeech {
                    Button {
                        vm.generateCaptions(allowCloudFallback: true)
                    } label: {
                        Label("Retry via Apple's cloud", systemImage: "icloud.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.small)
                    .disabled(vm.isTranscribing)
                    Text("Sends this recording's audio to Apple for speech recognition. Only for this one request.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(vm.isExporting)
    }
}
