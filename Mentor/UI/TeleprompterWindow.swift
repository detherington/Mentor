import AppKit
import SwiftUI

/// Non-activating floating panel that hosts the teleprompter. The user
/// can show/hide it independently of recording — it's a utility like
/// the webcam preview, not a recording-only component. Clicks don't
/// steal focus from whatever app the user is recording.
@MainActor
final class TeleprompterWindow: NSPanel {
    init(controller: TeleprompterController) {
        let initial = NSRect(x: 0, y: 0, width: 720, height: 520)
        super.init(
            contentRect: initial,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Teleprompter"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        titlebarAppearsTransparent = true

        let host = NSHostingView(rootView: TeleprompterView(controller: controller))
        host.autoresizingMask = [.width, .height]
        contentView = host

        // Default placement: right edge of main screen, vertically
        // centred, so it doesn't cover the area most users record from.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.maxX - initial.width - 40
            let y = visible.minY + (visible.height - initial.height) / 2
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct TeleprompterView: View {
    @Bindable var controller: TeleprompterController
    @State private var editingScript: Bool = false
    @State private var draftScript: String = ""
    @FocusState private var scriptFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial)

            Divider()

            if editingScript {
                scriptEditor
            } else {
                scriptDisplay
            }

            Divider()

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial)
        }
    }

    // MARK: - Top controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            // Play / pause — only meaningful when mode != .manual.
            Button {
                if controller.isTicking {
                    controller.stop()
                } else {
                    controller.start()
                }
            } label: {
                Image(systemName: controller.isTicking ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help("Start/stop autoscroll")
            .disabled(controller.settings.mode == .manual)

            Button {
                controller.resetProgress()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Jump back to the top of the script")

            Divider().frame(height: 18)

            Picker("Scroll", selection: Binding(
                get: { controller.settings.mode },
                set: { var s = controller.settings; s.mode = $0; controller.settings = s }
            )) {
                ForEach(TeleprompterScrollMode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)

            if controller.settings.mode != .manual {
                HStack(spacing: 6) {
                    Text("WPM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { controller.settings.wordsPerMinute },
                        set: { var s = controller.settings; s.wordsPerMinute = $0; controller.settings = s }
                    ), in: 40...400, step: 10) {
                        Text("\(controller.settings.wordsPerMinute)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 36, alignment: .trailing)
                    }
                }
            }

            Spacer()

            Button {
                if editingScript {
                    var s = controller.settings
                    s.script = draftScript
                    controller.settings = s
                    editingScript = false
                } else {
                    draftScript = controller.settings.script
                    editingScript = true
                }
            } label: {
                Label(editingScript ? "Done" : "Edit script",
                      systemImage: editingScript ? "checkmark" : "square.and.pencil")
            }
        }
    }

    // MARK: - Script editor

    @ViewBuilder
    private var scriptEditor: some View {
        TextEditor(text: $draftScript)
            .font(.system(size: 14))
            .padding(12)
            .focused($scriptFieldFocused)
            .onAppear { scriptFieldFocused = true }
    }

    // MARK: - Script display (reading mode)

    @ViewBuilder
    private var scriptDisplay: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Top padding so the first line lands in the
                        // readable middle of the window, not flush
                        // against the top.
                        Color.clear.frame(height: geo.size.height * 0.35)
                            .id("teleprompter-top")

                        Text(controller.settings.script.isEmpty
                             ? "Click \"Edit script\" to paste your script."
                             : controller.settings.script)
                            .font(.system(size: controller.settings.fontSize, weight: .medium, design: .serif))
                            .foregroundStyle(.primary)
                            .lineSpacing(controller.settings.fontSize * 0.32)
                            .multilineTextAlignment(.leading)
                            .frame(
                                maxWidth: geo.size.width * controller.settings.lineWidthFraction,
                                alignment: .leading
                            )
                            .padding(.horizontal, geo.size.width * (1 - controller.settings.lineWidthFraction) / 2)
                            .scaleEffect(x: controller.settings.mirrored ? -1 : 1, y: 1)
                            .id("teleprompter-body")

                        // Bottom padding so the last line can scroll
                        // into the reading zone instead of stopping at
                        // the bottom of the window.
                        Color.clear.frame(height: geo.size.height * 0.65)
                            .id("teleprompter-bottom")
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .onChange(of: controller.progress) { _, newValue in
                    // Translate 0-1 progress into a smooth scroll
                    // anchor. SwiftUI doesn't give us a fine-grained
                    // contentOffset binding; scrollTo(..anchor:) is
                    // the closest tool. We pick an anchor between
                    // top and bottom based on progress — gives a
                    // near-continuous scroll feel with only two
                    // anchor IDs, and SwiftUI interpolates.
                    withAnimation(.linear(duration: 0.05)) {
                        if newValue < 0.05 {
                            proxy.scrollTo("teleprompter-top", anchor: .top)
                        } else if newValue > 0.95 {
                            proxy.scrollTo("teleprompter-bottom", anchor: .bottom)
                        } else {
                            // Use a custom UnitPoint anchor derived
                            // from progress. SwiftUI's scrollTo
                            // accepts any UnitPoint, so this gives
                            // smooth progressive positioning.
                            proxy.scrollTo("teleprompter-body", anchor: UnitPoint(x: 0.5, y: newValue))
                        }
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
        .contentShape(Rectangle())
        // Arrow keys + space control scroll when the reading area has
        // focus. Manual mode uses these; timer / follow-voice modes
        // still let the user nudge without disabling the auto-tick.
        .onKeyPress(.upArrow)    { controller.nudgeProgress(by: -0.01); return .handled }
        .onKeyPress(.downArrow)  { controller.nudgeProgress(by: 0.01);  return .handled }
        .onKeyPress(.pageUp)     { controller.nudgeProgress(by: -0.05); return .handled }
        .onKeyPress(.pageDown)   { controller.nudgeProgress(by: 0.05);  return .handled }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            // Font size slider — small footprint so it doesn't
            // compete with the scroll controls for attention.
            Image(systemName: "textformat.size")
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { controller.settings.fontSize },
                    set: { var s = controller.settings; s.fontSize = $0; controller.settings = s }
                ),
                in: 18...72
            )
            .frame(width: 140)
            Text("\(Int(controller.settings.fontSize))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)

            Divider().frame(height: 18)

            Toggle("Mirror", isOn: Binding(
                get: { controller.settings.mirrored },
                set: { var s = controller.settings; s.mirrored = $0; controller.settings = s }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Horizontally flip the text for a through-the-glass teleprompter rig")

            Spacer()

            if controller.settings.mode == .followVoice {
                HStack(spacing: 4) {
                    Circle()
                        .fill(controller.isSpeaking ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    // Little VU-style meter showing the smoothed
                    // envelope so the user can see the amplitude
                    // gate's behaviour at a glance.
                    SpeakingMeter(level: controller.speakingLevel)
                        .frame(width: 60, height: 8)
                }
                .help("Live mic amplitude — scrolls while the bar is green")
            }

            // Progress readout.
            Text("\(Int(controller.progress * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

private struct SpeakingMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green.opacity(0.75))
                    .frame(width: CGFloat(level) * geo.size.width)
            }
        }
    }
}
