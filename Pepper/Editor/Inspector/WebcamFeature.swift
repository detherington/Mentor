import SwiftUI
import AppKit
import AVFoundation

/// Webcam row: shape, corner, size, what's behind you, fades, and
/// full-screen moments (talking-head keyframes, which used to be their
/// own section with their own jargon).
struct WebcamFeature: View {
    @Bindable var vm: EditorViewModel

    /// The switch hides the bubble. Switching it back on returns to the
    /// bottom-right corner: hiding clears a dragged spot anyway.
    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.webcamPosition != .hidden },
            set: { vm.webcamPosition = $0 ? .bottomRight : .hidden }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        guard vm.webcamPosition != .hidden else { return "Off" }
        let place = vm.webcamCustomOrigin != nil ? "your spot" : vm.webcamPosition.label.lowercased()
        var parts = ["\(shapeName(vm.webcamShape)), \(place)"]
        switch vm.webcamBackgroundStyle.mode {
        case .off:         break
        case .blur:        parts.append("background blurred")
        case .color:       parts.append("background colored")
        case .transparent: parts.append("background removed")
        }
        return parts.joined(separator: ", ")
    }

    static func shapeName(_ shape: WebcamShape) -> String {
        switch shape {
        case .circle:        return "Circle"
        case .roundedSquare: return "Rounded"
        case .none:          return "Rectangle"
        }
    }

    var body: some View {
        FieldLabel("Shape")
        HStack(spacing: 6) {
            ForEach(WebcamShape.allCases) { shape in
                ShapeTile(shape: shape, isSelected: vm.webcamShape == shape) {
                    vm.webcamShape = shape
                }
            }
        }

        HStack(alignment: .center, spacing: 12) {
            CornerPicker(selection: vm.webcamCustomOrigin == nil ? vm.webcamPosition : nil) { corner in
                // Picking the corner it's already in still has to drop a
                // dragged spot — the position setter only clears it on a
                // change.
                vm.webcamCustomOrigin = nil
                vm.webcamPosition = corner
            }
            VStack(alignment: .leading, spacing: 3) {
                FieldLabel("Position")
                Note(vm.webcamCustomOrigin != nil
                     ? "Where you dragged it. Pick a corner to snap back."
                     : "Pick a corner, or drag the webcam in the preview.")
            }
        }

        PlainSlider(
            label: "Size",
            value: Binding(get: { Double(vm.webcamDiameter) }, set: { vm.webcamDiameter = CGFloat($0) }),
            range: Double(vm.diameterMin)...Double(vm.diameterMax),
            low: "Small", high: "Large"
        )

        FieldLabel("Background behind you")
        ChoiceStrip(
            label: "Background behind you",
            options: [("As is", WebcamBackgroundMode.off), ("Blur", .blur), ("Color", .color), ("Remove", .transparent)],
            selection: Binding(
                get: { vm.webcamBackgroundStyle.mode },
                set: { var s = vm.webcamBackgroundStyle; s.mode = $0; vm.webcamBackgroundStyle = s }
            )
        )
        switch vm.webcamBackgroundStyle.mode {
        case .off:
            EmptyView()
        case .blur:
            PlainSlider(
                label: "Blur",
                value: Binding(
                    get: { vm.webcamBackgroundStyle.blurRadius },
                    set: { var s = vm.webcamBackgroundStyle; s.blurRadius = $0; vm.webcamBackgroundStyle = s }
                ),
                range: 4...40, low: "Soft", high: "Strong"
            )
        case .color:
            ColorPicker("Background color", selection: Binding(
                get: {
                    let s = vm.webcamBackgroundStyle
                    return Color(red: s.red, green: s.green, blue: s.blue)
                },
                set: { newColor in
                    let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                    var s = vm.webcamBackgroundStyle
                    s.red = ns.redComponent
                    s.green = ns.greenComponent
                    s.blue = ns.blueComponent
                    vm.webcamBackgroundStyle = s
                }
            ))
            .font(.system(size: 12.5))
        case .transparent:
            Note("Your background disappears and the screen shows through.")
        }

        Toggle("Fade in and out", isOn: Binding(
            get: { vm.webcamTransitions.fadeIn > 0 || vm.webcamTransitions.fadeOut > 0 },
            set: { vm.webcamTransitions = $0 ? WebcamTransitions(fadeIn: 0.5, fadeOut: 0.5) : WebcamTransitions(fadeIn: 0, fadeOut: 0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12.5))

        Divider()

        fullScreenMoments

        MoreOptions {
            PlainSlider(
                label: "Distance from the edge",
                value: Binding(get: { Double(vm.webcamInset) }, set: { vm.webcamInset = CGFloat($0) }),
                range: 0...Double(vm.diameterMax * 0.6),
                low: "Close", high: "Far"
            )
            PlainSlider(
                label: "Fade in",
                value: Binding(
                    get: { vm.webcamTransitions.fadeIn },
                    set: { vm.webcamTransitions = WebcamTransitions(fadeIn: $0, fadeOut: vm.webcamTransitions.fadeOut) }
                ),
                range: 0...3, low: "None", high: "Slow"
            )
            PlainSlider(
                label: "Fade out",
                value: Binding(
                    get: { vm.webcamTransitions.fadeOut },
                    set: { vm.webcamTransitions = WebcamTransitions(fadeIn: vm.webcamTransitions.fadeIn, fadeOut: $0) }
                ),
                range: 0...3, low: "None", high: "Slow"
            )
            if !vm.talkingHeadKeyframes.isEmpty {
                PlainSlider(
                    label: "Full-screen size",
                    value: Binding(
                        get: { Double(vm.talkingHeadKeyframes.first?.targetDiameterFraction ?? 0.6) },
                        set: { vm.setSizeForAllTalkingHeads(CGFloat($0)) }
                    ),
                    range: 0.2...0.95, low: "Smaller", high: "Fills the screen"
                )
            }
            if vm.webcamBackgroundStyle.mode != .off {
                FieldLabel("Background edges")
                ChoiceStrip(
                    label: "Background edges",
                    options: [("Fast", 2), ("Balanced", 1), ("Best", 0)],
                    selection: Binding(
                        get: { vm.webcamBackgroundStyle.qualityLevel },
                        set: { var s = vm.webcamBackgroundStyle; s.qualityLevel = $0; vm.webcamBackgroundStyle = s }
                    )
                )
                Note("Best gives cleaner hair edges but can make the preview stutter. The export always looks right.")
            }
        }
    }

    @ViewBuilder
    private var fullScreenMoments: some View {
        RowHeading("Full-screen moments")
        Note("Make the webcam fill the screen for a few seconds, then shrink back. They show in green on the timeline; drag one to move it.")
        ForEach(vm.talkingHeadKeyframes) { kf in
            let hold = CMTimeGetSeconds(CMTimeSubtract(kf.holdEndTime, CMTimeAdd(kf.startTime, kf.inDuration)))
            HStack(spacing: 6) {
                Button {
                    vm.seek(to: kf.peakStartTime)
                } label: {
                    Text("At \(InspectorFormat.time(kf.startTime)), for \(InspectorFormat.seconds(hold))")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Jump to this moment")
                Spacer()
                Button {
                    vm.removeTalkingHeadKeyframe(id: kf.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove the moment at \(InspectorFormat.time(kf.startTime))")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Brand.chip, in: RoundedRectangle(cornerRadius: Brand.Radius.chip, style: .continuous))
        }
        PlayheadGatedButton(
            title: "Fill the screen at the playhead",
            help: "Add a full-screen moment where the playhead is.",
            isEnabled: { vm.canAddTalkingHeadAtPlayhead },
            action: { vm.addTalkingHeadAtPlayhead() }
        )
    }
}

/// A shape to pick, drawn as the shape itself.
private struct ShapeTile: View {
    let shape: WebcamShape
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                glyph
                    .fill(isSelected ? Color.primary : Color.secondary.opacity(0.6))
                    .frame(width: shape == .none ? 24 : 18, height: shape == .none ? 16 : 18)
                Text(WebcamFeature.shapeName(shape))
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                isSelected ? Brand.accent.opacity(0.14) : Brand.chip,
                in: RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.field, style: .continuous)
                    .strokeBorder(isSelected ? Brand.accent : Brand.hairline, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shape: \(WebcamFeature.shapeName(shape))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var glyph: AnyShape {
        switch shape {
        case .circle:        return AnyShape(Circle())
        case .roundedSquare: return AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        case .none:          return AnyShape(RoundedRectangle(cornerRadius: 1.5))
        }
    }
}

/// A miniature frame with a dot in each corner: click one to put the
/// webcam there. `selection` is nil while it sits at a dragged spot.
private struct CornerPicker: View {
    let selection: WebcamPosition?
    let pick: (WebcamPosition) -> Void

    private let corners: [(WebcamPosition, Alignment, String)] = [
        (.topLeft, .topLeading, "Top left"),
        (.topRight, .topTrailing, "Top right"),
        (.bottomLeft, .bottomLeading, "Bottom left"),
        (.bottomRight, .bottomTrailing, "Bottom right"),
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Brand.chip)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Brand.hairline)
            ForEach(corners.indices, id: \.self) { i in
                let (corner, alignment, name) = corners[i]
                Button {
                    pick(corner)
                } label: {
                    Circle()
                        .fill(selection == corner ? Brand.accent : Color.clear)
                        .overlay(Circle().strokeBorder(selection == corner ? Brand.accent : Color.secondary.opacity(0.6), lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .padding(7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(selection == corner ? .isSelected : [])
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            }
        }
        .frame(width: 112, height: 64)
    }
}
