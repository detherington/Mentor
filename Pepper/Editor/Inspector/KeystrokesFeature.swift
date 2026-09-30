import SwiftUI

/// Show keystrokes row: the key presses from the recording, as chips on
/// screen.
struct KeystrokesFeature: View {
    @Bindable var vm: EditorViewModel

    private static let sizes: [(String, Double)] = [("Small", 0.022), ("Medium", 0.028), ("Large", 0.038)]

    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.keystrokeOverlayStyle.enabled },
            set: { var s = vm.keystrokeOverlayStyle; s.enabled = $0; vm.keystrokeOverlayStyle = s }
        )
    }

    /// Any key presses in the recording at all. The chips alone can't
    /// tell: with "Shortcuts only" they leave out plain typing.
    private static func recordedKeys(_ vm: EditorViewModel) -> Bool {
        vm.project.eventLog?.events.contains { $0.type == "key" } ?? false
    }

    static func status(_ vm: EditorViewModel) -> String {
        guard vm.keystrokeOverlayStyle.enabled else { return "Off" }
        if !recordedKeys(vm) { return "No key presses were recorded" }
        if vm.keystrokeChips.isEmpty { return "No shortcuts in this recording" }
        return vm.keystrokeOverlayStyle.showPlainKeys ? "Everything you type" : "The shortcuts you press"
    }

    var body: some View {
        if !Self.recordedKeys(vm) {
            Note("Pepper didn't see any key presses in this recording. It needs Accessibility turned on (Settings › Setup) to show them in future recordings.")
        } else if vm.keystrokeChips.isEmpty {
            Note("You didn't press any shortcuts. Choose Everything typed to show your typing too.")
        }
        FieldLabel("Show")
        ChoiceStrip(
            label: "Show",
            options: [("Shortcuts only", false), ("Everything typed", true)],
            selection: Binding(
                get: { vm.keystrokeOverlayStyle.showPlainKeys },
                set: { var s = vm.keystrokeOverlayStyle; s.showPlainKeys = $0; vm.keystrokeOverlayStyle = s }
            )
        )
        Note("Shortcuts are key combinations like ⌘C, plus keys like Return and Tab.")
        FieldLabel("Size")
        ChoiceStrip(
            label: "Keystroke size",
            options: Self.sizes.map { (label: $0.0, value: $0.0) },
            selection: Binding(
                get: { InspectorFormat.nearest(vm.keystrokeOverlayStyle.fontSizeFraction, in: Self.sizes.map { ($0.0, $0.1) }) },
                set: { name in
                    guard let preset = Self.sizes.first(where: { $0.0 == name }) else { return }
                    var s = vm.keystrokeOverlayStyle; s.fontSizeFraction = preset.1; vm.keystrokeOverlayStyle = s
                }
            )
        )
        PlainSlider(
            label: "How long each one shows",
            value: Binding(
                get: { vm.keystrokeOverlayStyle.displayDuration },
                set: { var s = vm.keystrokeOverlayStyle; s.displayDuration = $0; vm.keystrokeOverlayStyle = s }
            ),
            range: 0.4...3.0, low: "Quick", high: "Long"
        )
        MoreOptions {
            PlainSlider(
                label: "Height on screen",
                value: Binding(
                    get: { vm.keystrokeOverlayStyle.bottomInsetFraction },
                    set: { var s = vm.keystrokeOverlayStyle; s.bottomInsetFraction = $0; vm.keystrokeOverlayStyle = s }
                ),
                range: 0.02...0.35, low: "Low", high: "High"
            )
        }
    }
}
