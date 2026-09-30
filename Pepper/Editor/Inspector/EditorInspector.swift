import SwiftUI
import AVFoundation

/// The inspector's rows, in display order.
enum InspectorFeature: String, CaseIterable, Identifiable {
    case webcam, zoom, cursor, audio, cuts, captions, keystrokes, titles
    var id: String { rawValue }
}

/// The editor's right-hand panel: a short checklist of effects, each a
/// row with a plain name, a one-line status and an on/off switch, that
/// opens in place to show its few settings. It replaced a single long
/// column of every control at once (with export at the very bottom),
/// which new users found hard to scan. Export and the recording's
/// details live in the window toolbar now.
///
/// One row is open at a time (`EditorViewModel.openInspectorFeature`);
/// clicking a zoom, caption, keystroke or the webcam opens its row too.
struct EditorInspector: View {
    @Bindable var vm: EditorViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    QuickPolishCard(vm: vm)
                        .padding(.bottom, 6)

                    GroupLabel("Video")
                    FeatureRow(vm: vm, feature: .webcam, title: "Webcam bubble", systemImage: "video",
                               status: WebcamFeature.status(vm), isOn: WebcamFeature.isOn(vm)) {
                        WebcamFeature(vm: vm)
                    }
                    FeatureRow(vm: vm, feature: .zoom, title: "Smart zoom", systemImage: "plus.magnifyingglass",
                               status: ZoomFeature.status(vm), isOn: $vm.zoomEnabled) {
                        ZoomFeature(vm: vm)
                    }
                    FeatureRow(vm: vm, feature: .cursor, title: "Cursor & clicks", systemImage: "cursorarrow.click",
                               status: CursorFeature.status(vm), isOn: CursorFeature.isOn(vm)) {
                        CursorFeature(vm: vm)
                    }

                    GroupLabel("Sound")
                    FeatureRow(vm: vm, feature: .audio, title: "Clean up audio", systemImage: "waveform",
                               status: AudioFeature.status(vm), isOn: AudioFeature.isOn(vm)) {
                        AudioFeature(vm: vm)
                    }
                    FeatureRow(vm: vm, feature: .cuts, title: "Cuts", systemImage: "scissors",
                               status: CutsFeature.status(vm), isOn: nil) {
                        CutsFeature(vm: vm)
                    }

                    GroupLabel("Text")
                    FeatureRow(vm: vm, feature: .captions, title: "Captions", systemImage: "captions.bubble",
                               status: CaptionsFeature.status(vm), isOn: CaptionsFeature.isOn(vm)) {
                        CaptionsFeature(vm: vm)
                    }
                    FeatureRow(vm: vm, feature: .keystrokes, title: "Show keystrokes", systemImage: "keyboard",
                               status: KeystrokesFeature.status(vm), isOn: KeystrokesFeature.isOn(vm)) {
                        KeystrokesFeature(vm: vm)
                    }
                    FeatureRow(vm: vm, feature: .titles, title: "Title cards", systemImage: "rectangle.center.inset.filled",
                               status: TitleCardsFeature.status(vm), isOn: TitleCardsFeature.isOn(vm)) {
                        TitleCardsFeature(vm: vm)
                    }
                }
                .padding(12)
            }
            // Muesli's look: a ground strip carrying surface cards.
            .background(Brand.ground)
            .disabled(vm.isExporting)
            // Opened from the timeline or preview: bring the row into view.
            .onChange(of: vm.openInspectorFeature) { _, feature in
                guard let feature else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(feature, anchor: .top)
                    }
                }
            }
            // A caption picked on the timeline: open Captions, then scroll
            // to its line once the row and its edit list have laid out
            // (after the row-level scroll above).
            .onChange(of: vm.focusedCaptionLineId) { _, id in
                guard let id else { return }
                vm.openInspectorFeature = .captions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

// MARK: - Row

/// One effect: icon, name, status line, optional switch, and its
/// settings when open.
struct FeatureRow<Content: View>: View {
    @Bindable var vm: EditorViewModel
    let feature: InspectorFeature
    let title: String
    let systemImage: String
    let status: String
    /// Nil for a row with nothing to switch (Cuts).
    let isOn: Binding<Bool>?
    @ViewBuilder var content: () -> Content

    private var isOpen: Bool { vm.openInspectorFeature == feature }
    private var looksOn: Bool { isOn?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        vm.openInspectorFeature = isOpen ? nil : feature
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: systemImage)
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 28, height: 28)
                            .foregroundStyle(looksOn ? Brand.accentText : Color.secondary)
                            .background(
                                looksOn ? Brand.accent.opacity(0.14) : Brand.chip,
                                in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous)
                            )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(status)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(status)")
                .accessibilityHint(isOpen ? "Hides its settings" : "Shows its settings")

                if let isOn {
                    Toggle(title, isOn: isOn)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
        }
        .brandCard(radius: Brand.Radius.field)
        .id(feature)
    }
}

// MARK: - Quick polish

private struct QuickPolishCard: View {
    let vm: EditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                // Violet: what Pepper does for you, as Muesli marks AI.
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Brand.violet)
                Text("Quick polish").brandDisplay(14)
            }
            Note("Zoom into your clicks, add captions and cut long pauses, all in one go. You can fine-tune anything below.")
            // The panel's one Neon call to action.
            Button {
                vm.quickPolish()
            } label: {
                HStack(spacing: 6) {
                    if vm.isPolishing {
                        ProgressView().controlSize(.small).tint(.black)
                    }
                    Text(vm.isPolishing ? "Polishing…" : "Polish my video")
                }
            }
            .buttonStyle(NeonButtonStyle(height: 34, fullWidth: true))
            .disabled(vm.isPolishing || vm.isLoading || vm.loadError != nil)
        }
        .padding(14)
        .brandCard()
    }
}

// MARK: - Shared pieces

/// "VIDEO", "SOUND", "TEXT" above each group of rows.
struct GroupLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .brandKicker(10.5)
            .padding(.top, 10)
            .padding(.horizontal, 4)
    }
}

/// A setting's name, above its control.
struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

/// A line of explanation under or between controls.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A sub-heading inside an open row.
struct RowHeading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12.5, weight: .semibold))
    }
}

/// A slider labelled with words at each end instead of units: people
/// pick "Small…Large", not "341 pt".
struct PlainSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            FieldLabel(label)
            Slider(value: $value, in: range) { Text(label) }
                .labelsHidden()
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }
}

/// Equal-width choices in a strip. Not a segmented `Picker`: those can't
/// shrink below their labels' natural width, and overflowed (and
/// clipped) the inspector column before. These truncate instead.
struct ChoiceStrip<Value: Hashable>: View {
    let label: String
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        // Selected segment raised like a native segmented
                        // control, which Muesli keeps as-is.
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlColor))
                                    .shadow(color: .black.opacity(0.22), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(label): \(option.label)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Brand.chip, in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous))
    }
}

/// Plain-language settings tucked away for people who want them.
struct MoreOptions<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Text("More options").font(.system(size: 12))
        }
    }
}

enum InspectorFormat {
    /// "1:07" — minutes and whole seconds, for people rather than editors.
    static func time(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite else { return "--" }
        let total = Int(max(0, seconds).rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "3 s", "1.5 s".
    static func seconds(_ s: Double) -> String {
        guard s.isFinite else { return "--" }
        return s < 10 && s != s.rounded() ? String(format: "%.1f s", s) : "\(Int(s.rounded())) s"
    }

    /// The preset whose value is closest to `value`.
    static func nearest<V: Hashable>(_ value: Double, in presets: [(V, Double)]) -> V {
        presets.min(by: { abs($0.1 - value) < abs($1.1 - value) })!.0
    }
}
