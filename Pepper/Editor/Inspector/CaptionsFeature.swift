import SwiftUI

/// Captions row: write them from the narration, pick a size and height,
/// fix any line, and optionally save a subtitle file alongside the video.
struct CaptionsFeature: View {
    @Bindable var vm: EditorViewModel

    private static let sizes: [(String, Double)] = [("Small", 0.035), ("Medium", 0.045), ("Large", 0.06)]
    private static let heights: [(String, Double)] = [("Bottom", 0.06), ("Raised", 0.16)]

    /// Switching on with no captions yet writes them.
    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.isTranscribing || (vm.transcription != nil && vm.captionStyle.enabled) },
            set: { on in
                var s = vm.captionStyle
                s.enabled = on
                vm.captionStyle = s
                if on, vm.transcription == nil { vm.generateCaptions() }
            }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        if vm.isTranscribing { return "Writing captions…" }
        guard let log = vm.transcription, vm.captionStyle.enabled else { return "Off" }
        return "\(log.lines.count) line\(log.lines.count == 1 ? "" : "s") from your narration"
    }

    var body: some View {
        if vm.isTranscribing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Note("Writing captions from your narration…")
            }
        } else if let log = vm.transcription {
            FieldLabel("Size")
            ChoiceStrip(
                label: "Caption size",
                options: Self.sizes.map { (label: $0.0, value: $0.0) },
                selection: Binding(
                    get: { InspectorFormat.nearest(vm.captionStyle.fontSizeFraction, in: Self.sizes.map { ($0.0, $0.1) }) },
                    set: { name in
                        guard let preset = Self.sizes.first(where: { $0.0 == name }) else { return }
                        var s = vm.captionStyle; s.fontSizeFraction = preset.1; vm.captionStyle = s
                    }
                )
            )
            FieldLabel("Position")
            ChoiceStrip(
                label: "Caption position",
                options: Self.heights.map { (label: $0.0, value: $0.0) },
                selection: Binding(
                    get: { InspectorFormat.nearest(vm.captionStyle.bottomInsetFraction, in: Self.heights.map { ($0.0, $0.1) }) },
                    set: { name in
                        guard let preset = Self.heights.first(where: { $0.0 == name }) else { return }
                        var s = vm.captionStyle; s.bottomInsetFraction = preset.1; vm.captionStyle = s
                    }
                )
            )
            Note("Raised keeps them clear of a webcam in a bottom corner.")

            CaptionEditList(vm: vm, lines: log.lines)

            Toggle("Also save a subtitle file", isOn: $vm.exportSRTSidecar)
                .toggleStyle(.checkbox)
                .font(.system(size: 12.5))
                .help("Saves an .srt file next to the exported video, for YouTube and video editors.")

            MoreOptions {
                HStack(spacing: 8) {
                    Button("Write them again") { vm.generateCaptions() }
                        .controlSize(.small)
                    Button("Remove captions", role: .destructive) { vm.clearCaptions() }
                        .controlSize(.small)
                }
                Note("Writing them again replaces any lines you've edited.")
            }
        } else {
            Note("Pepper writes captions from your narration, right on this Mac. You can fix any line afterwards.")
            Button {
                vm.generateCaptions()
            } label: {
                Text("Write captions").frame(maxWidth: .infinity)
            }
        }

        if let error = vm.transcriptionError {
            Text(error.localizedDescription)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            // On-device recognition sometimes hears nothing even when
            // Dictation works; offer Apple's servers for this one request.
            if vm.transcriptionErrorIsNoSpeech {
                Button {
                    vm.generateCaptions(allowCloudFallback: true)
                } label: {
                    Label("Try again with Apple's servers", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(vm.isTranscribing)
                Note("Sends this recording's audio to Apple for this one request.")
            }
        }
    }
}
