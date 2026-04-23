import SwiftUI
import AppKit

/// Modal sheet presented from the editor's inspector via
/// "Export to Orbis". Captures form inputs (title, visibility,
/// client, assets opt-in) and hands them to `OrbisExportController`
/// which runs the render-then-upload flow. The sheet observes the
/// controller's phase + progress so the user sees one coherent
/// progress bar across "Rendering" / "Uploading" / "Finalizing".
struct OrbisExportSheet: View {
    let vm: EditorViewModel
    let onClose: () -> Void

    // Controller owns the render+upload; kept in @State so the
    // sheet's lifetime matches the flow's lifetime.
    @State private var controller = OrbisExportController()

    // Form inputs, prefilled from UserDefaults + the recording's
    // filename so repeat exports don't require retyping.
    @State private var title: String
    @State private var description: String = ""
    @State private var visibility: OrbisVisibility
    @State private var selectedClientID: String?
    @State private var includeAssets: Bool
    @State private var clients: [OrbisClientInfo] = []
    @State private var loadingClients: Bool = false
    @State private var clientsError: String?

    init(vm: EditorViewModel, onClose: @escaping () -> Void) {
        self.vm = vm
        self.onClose = onClose
        let defaultTitle = vm.project.bundleURL.deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "Mentor_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        _title           = State(initialValue: defaultTitle)
        _visibility      = State(initialValue: OrbisSettings.shared.lastVisibility)
        _selectedClientID = State(initialValue: OrbisSettings.shared.lastClientID)
        _includeAssets   = State(initialValue: OrbisSettings.shared.ingestAssetsEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            switch controller.phase {
            case .finished(let videoID):
                successView(videoID: videoID)
            case .failed(let message):
                failureView(message: message)
            default:
                form
            }
        }
        .frame(width: 520)
        .task { await loadClientsIfNeeded() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Image(systemName: "arrow.up.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
            Text("Export to Orbis").font(.headline)
            Spacer()
            if let name = OrbisSettings.shared.connectedUserName {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section {
                    Picker("Visibility", selection: $visibility) {
                        ForEach(OrbisVisibility.allCases) {
                            Text($0.label).tag($0)
                        }
                    }
                    if visibility == .client {
                        clientPicker
                    }
                }
                Section {
                    Toggle("Include transcript & thumbnail", isOn: $includeAssets)
                        .help(vm.project.transcription == nil
                              ? "Mentor will still send a thumbnail; transcript isn't available for this recording."
                              : "Sends the Mentor-generated transcript so Orbis can skip AssemblyAI processing.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            progressBar
                .padding(.horizontal)
                .padding(.bottom, 8)

            footer
        }
    }

    @ViewBuilder
    private var clientPicker: some View {
        if loadingClients {
            HStack { ProgressView().controlSize(.small); Text("Loading clients…") }
        } else if let err = clientsError {
            Text(err).font(.caption).foregroundStyle(.red)
        } else if clients.isEmpty {
            Text("No clients available. Ask an Orbis admin to add one, or pick another visibility.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Client", selection: $selectedClientID) {
                Text("Select…").tag(String?.none)
                ForEach(clients) { c in
                    Text(c.name).tag(Optional(c.id))
                }
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .preparing, .rendering, .reserving, .uploading, .ingesting, .completing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: controller.progress)
                Text(phaseLabel(controller.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                controller.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                startExport()
            } label: {
                Text(startButtonTitle).frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canStart)
        }
        .padding()
    }

    @ViewBuilder
    private func successView(videoID: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title)
                VStack(alignment: .leading) {
                    Text("Upload complete").font(.headline)
                    Text("Orbis is processing the video. It'll appear in the library shortly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("View in Orbis") {
                    if let url = OrbisSettings.shared.videoURL(videoID: videoID) {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Done") { onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func failureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upload failed").font(.headline)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Close") { onClose() }
                Button("Retry") {
                    // Fresh controller — the old one's state is
                    // terminal. The render will run again from
                    // scratch, which is the right thing for R2 since
                    // PUT URLs aren't resumable.
                    controller = OrbisExportController()
                    startExport()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Logic

    private var canStart: Bool {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if visibility == .client && selectedClientID == nil { return false }
        switch controller.phase {
        case .idle, .failed: return true
        default:             return false
        }
    }

    private var startButtonTitle: String {
        switch controller.phase {
        case .idle, .failed: return "Upload"
        default:             return "Uploading…"
        }
    }

    private func phaseLabel(_ phase: OrbisExportController.Phase) -> String {
        switch phase {
        case .preparing:  return "Preparing…"
        case .rendering:  return "Rendering the current layout to MP4…"
        case .reserving:  return "Reserving a video slot on Orbis…"
        case .uploading:  return "Uploading to Orbis…"
        case .ingesting:  return "Sending transcript & thumbnail…"
        case .completing: return "Finalizing…"
        default:          return ""
        }
    }

    private func startExport() {
        // Persist form choices for next time.
        OrbisSettings.shared.lastVisibility = visibility
        OrbisSettings.shared.lastClientID = (visibility == .client) ? selectedClientID : nil
        OrbisSettings.shared.ingestAssetsEnabled = includeAssets

        let request = OrbisExportController.Request(
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            visibility: visibility,
            clientID: (visibility == .client) ? selectedClientID : nil,
            includeAssets: includeAssets,
            layout: vm.currentExportLayout(),
            trimMap: vm.currentExportTrimMap(),
            bundle: vm.project.bundle,
            metadata: vm.project.metadata,
            transcription: vm.project.transcription,
            recordedAt: vm.project.metadata.startDate
        )
        controller.start(request)
    }

    /// Fetch available clients once per sheet lifetime so the picker
    /// has something to render when the user flips visibility to
    /// Client. Runs even when visibility is not Client — the fetch
    /// is cheap and switching to Client shouldn't introduce a spinner.
    private func loadClientsIfNeeded() async {
        guard clients.isEmpty, let token = OrbisKeychain.loadToken() else { return }
        loadingClients = true
        clientsError = nil
        let client = OrbisClient(host: OrbisSettings.shared.host, token: token)
        do {
            let list = try await client.listClients()
            clients = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            clientsError = error.localizedDescription
        }
        loadingClients = false
    }
}
