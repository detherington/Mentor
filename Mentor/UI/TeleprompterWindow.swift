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
        // Non-opaque + clear background so the SwiftUI content can
        // draw its own translucency controlled by the user's opacity
        // slider. With `.titled` + titlebarAppearsTransparent, the
        // titlebar follows the content's background alpha too — so
        // at opacity 0 the chrome disappears and only text remains.
        isOpaque = false
        backgroundColor = .clear

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

    /// True when the three persisted RGB components are close enough
    /// to the default that the reset button has nothing to change.
    /// A small tolerance copes with sRGB float round-trips through the
    /// system colour picker (the value we set and the value we read
    /// back can differ by a few ULPs).
    private var isTextColourAtDefault: Bool {
        let d = TeleprompterSettings.default
        let tol: CGFloat = 0.005
        return abs(controller.settings.textRed   - d.textRed)   < tol
            && abs(controller.settings.textGreen - d.textGreen) < tol
            && abs(controller.settings.textBlue  - d.textBlue)  < tol
    }
    // Hover state for chrome reveal. When the mouse is over the
    // window we force the chrome to be visible even if the user has
    // set opacity to 0 — otherwise they'd have no way to pull the
    // slider back up. The script area keeps following the user's
    // setting so read-through still works when they move the mouse
    // away to whatever they're recording.
    @State private var isHovering: Bool = false

    var body: some View {
        let userAlpha = controller.settings.backgroundOpacity
        // Chrome opacity: max of user's setting and the hover-reveal
        // floor. 0.35 is low enough to feel unobtrusive over a
        // recorded background but high enough that all controls read
        // cleanly and the slider handle is easy to grab. When user
        // alpha already exceeds the floor, `max` keeps their value
        // unchanged — no jarring pop on hover at higher opacity.
        let chromeAlpha: CGFloat = max(userAlpha, isHovering ? 0.35 : 0)
        VStack(spacing: 0) {
            controls
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial)
                // Wrap the material in an opacity modifier — when the
                // user drops alpha the material itself becomes
                // translucent, so less blur work + less pixel cost per
                // frame. Dividers below pick up the same alpha so the
                // chrome fades as one unit.
                .opacity(Double(chromeAlpha))

            Divider()
                .opacity(Double(chromeAlpha))

            if editingScript {
                scriptEditor
                    .background(Color(nsColor: .textBackgroundColor).opacity(Double(userAlpha)))
            } else {
                scriptDisplay
                    .background(Color(nsColor: .textBackgroundColor).opacity(Double(userAlpha)))
            }

            Divider()
                .opacity(Double(chromeAlpha))

            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.thinMaterial)
                .opacity(Double(chromeAlpha))
        }
        .onHover { hovering in
            // Short animation so the reveal feels intentional — not a
            // harsh flash every time the mouse crosses the window
            // boundary.
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
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
                            .foregroundStyle(Color(
                                .sRGB,
                                red:   Double(controller.settings.textRed),
                                green: Double(controller.settings.textGreen),
                                blue:  Double(controller.settings.textBlue),
                                opacity: 1.0
                            ))
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

            Image(systemName: "square.dashed")
                .foregroundStyle(.secondary)
                .help("Background opacity — fades the panel chrome without touching the script text")
            Slider(
                value: Binding(
                    get: { controller.settings.backgroundOpacity },
                    set: { var s = controller.settings; s.backgroundOpacity = $0; controller.settings = s }
                ),
                in: 0.0...1.0
            )
            .frame(width: 100)
            Text(String(format: "%.0f%%", controller.settings.backgroundOpacity * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            Divider().frame(height: 18)

            Toggle("Mirror", isOn: Binding(
                get: { controller.settings.mirrored },
                set: { var s = controller.settings; s.mirrored = $0; controller.settings = s }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Horizontally flip the text for a through-the-glass teleprompter rig")

            Divider().frame(height: 18)

            // Text-colour picker. The window is a `.nonactivatingPanel`
            // so a raw SwiftUI ColorPicker click doesn't pull the app
            // to the foreground, and NSColorPanel needs an active app
            // to show — giving the appearance of "nothing happens on
            // click". We work around that by hosting an NSColorWell
            // directly and forcing `NSApp.activate` in the mouseDown
            // path, then pushing the selected colour back into the
            // persisted settings.
            TeleprompterTextColourWell(
                controller: controller
            )
            .frame(width: 100, height: 22)
            .help("Script text colour — click to open the system colour picker")

            // Reset-to-default button — returns the text colour to
            // the built-in warm near-white. Disabled (greyed) while
            // the current colour already matches the default so the
            // button only lights up when it'd actually do something.
            Button {
                var s = controller.settings
                let d = TeleprompterSettings.default
                s.textRed   = d.textRed
                s.textGreen = d.textGreen
                s.textBlue  = d.textBlue
                controller.settings = s
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isTextColourAtDefault)
            .help("Reset text colour to the default")

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

// MARK: - Text-colour well

/// Labelled NSColorWell wrapped for SwiftUI. Needed instead of a raw
/// `ColorPicker` because the teleprompter window is a non-activating
/// panel — SwiftUI's ColorPicker tries to open `NSColorPanel` but the
/// app isn't active, so the panel doesn't front-most and the click
/// feels like a no-op. Here we activate the app explicitly on
/// mouseDown, then let the well open the colour panel on the next
/// runloop pass once the app has focus.
@MainActor
private struct TeleprompterTextColourWell: NSViewRepresentable {
    let controller: TeleprompterController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSView {
        // Container hosts: "Text color" label + icon + the colour
        // well. Keeps the clickable hit-target obvious + accessible
        // so users know what the well is for.
        let container = NSStackView()
        container.orientation = .horizontal
        container.spacing = 6
        container.alignment = .centerY

        let icon = NSImageView(image: NSImage(systemSymbolName: "paintpalette.fill", accessibilityDescription: "Text colour")!)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setFrameSize(NSSize(width: 14, height: 14))
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14)
        ])

        let label = NSTextField(labelWithString: "Color")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let well = ActivatingColorWell()
        well.isBordered = true
        well.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: 40),
            well.heightAnchor.constraint(equalToConstant: 20)
        ])
        well.target = context.coordinator
        well.action = #selector(Coordinator.colourChanged(_:))
        well.color = context.coordinator.currentColor()
        context.coordinator.well = well

        container.addArrangedSubview(icon)
        container.addArrangedSubview(label)
        container.addArrangedSubview(well)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.well?.color = context.coordinator.currentColor()
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: TeleprompterController
        weak var well: NSColorWell?

        init(controller: TeleprompterController) {
            self.controller = controller
        }

        func currentColor() -> NSColor {
            NSColor(
                srgbRed: controller.settings.textRed,
                green:   controller.settings.textGreen,
                blue:    controller.settings.textBlue,
                alpha:   1.0
            )
        }

        @objc func colourChanged(_ sender: NSColorWell) {
            let nsColor = sender.color.usingColorSpace(.sRGB) ?? sender.color
            var s = controller.settings
            s.textRed   = nsColor.redComponent
            s.textGreen = nsColor.greenComponent
            s.textBlue  = nsColor.blueComponent
            controller.settings = s
        }
    }
}

/// NSColorWell subclass that activates the app before opening the
/// system colour panel. Without this override, clicking the well
/// inside a non-activating panel produces no visible response — the
/// colour panel is being opened but remains behind whatever window
/// currently owns the foreground.
private final class ActivatingColorWell: NSColorWell {
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        super.mouseDown(with: event)
    }
}
