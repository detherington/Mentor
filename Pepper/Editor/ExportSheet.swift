import SwiftUI
import AppKit

/// Modal sheet shown over the editor window during export, with progress
/// bar + cancel + error-state handling.
struct ExportSheet: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let err = viewModel.exportError {
                errorContent(err: err)
            } else {
                progressContent
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    @ViewBuilder
    private var progressContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Exporting edited video")
                    .font(.headline)
                Text("The render runs offline — no time limit on duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }

        ProgressView(value: viewModel.exportProgress)
            .progressViewStyle(.linear)

        HStack {
            Text("\(Int(viewModel.exportProgress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) {
                viewModel.cancelExport()
            }
            .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func errorContent(err: any Error) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(errorTitle(for: err))
                    .font(.headline)
                Text(err.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        HStack {
            Spacer()
            Button("Close") {
                viewModel.exportError = nil
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func errorTitle(for err: any Error) -> String {
        if case FinalRenderer.RenderError.cancelled = err {
            return "Export cancelled"
        }
        return "Export failed"
    }
}

/// The Quality choice, shown in the Export save panel. It used to be a
/// picker at the bottom of the inspector, far from the button it
/// affected.
enum ExportOptionsAccessory {
    @MainActor
    static func make(viewModel vm: EditorViewModel) -> NSView {
        let host = NSHostingView(rootView: ExportOptionsView(vm: vm))
        host.frame.size = host.fittingSize
        return host
    }
}

private struct ExportOptionsView: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Quality", selection: $vm.exportQuality) {
                ForEach(ExportQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(vm.exportQuality.sizeHint)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
    }
}
