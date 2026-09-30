import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Title-card thumbnails for the inspector, by asset filename (a UUID
/// per import, so an entry can never go stale).
@MainActor
private enum TitleCardThumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(for filename: String) -> NSImage? {
        if let hit = cache[filename] { return hit }
        guard let image = NSImage(contentsOf: TitleCardAssets.url(for: filename)) else { return nil }
        cache[filename] = image
        return image
    }
}

/// Title cards row: an opening title before the video and a closing
/// card after it.
struct TitleCardsFeature: View {
    @Bindable var vm: EditorViewModel

    /// On when either card is. Switching on adds the opening title;
    /// off removes both.
    static func isOn(_ vm: EditorViewModel) -> Binding<Bool> {
        Binding(
            get: { vm.startCard.enabled || vm.endCard.enabled },
            set: { on in
                var start = vm.startCard
                var end = vm.endCard
                if on {
                    start.enabled = true
                } else {
                    start.enabled = false
                    end.enabled = false
                }
                vm.startCard = start
                vm.endCard = end
            }
        )
    }

    static func status(_ vm: EditorViewModel) -> String {
        switch (vm.startCard.enabled, vm.endCard.enabled) {
        case (true, true):   return "Opening title and closing card"
        case (true, false):  return "Opening title"
        case (false, true):  return "Closing card"
        case (false, false): return "Off"
        }
    }

    var body: some View {
        cardEditor(
            label: "Opening title",
            card: Binding(get: { vm.startCard }, set: { vm.startCard = $0 })
        )

        Divider()

        cardEditor(
            label: "Closing card",
            card: Binding(get: { vm.endCard }, set: { vm.endCard = $0 })
        )

        Note("Cards fade in and out around your recording. They appear only in videos you export.")
    }

    @ViewBuilder
    private func cardEditor(label: String, card: Binding<TitleCard>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: card.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 12.5, weight: .semibold))

            if card.wrappedValue.enabled {
                TextField("Title", text: card.title)
                    .textFieldStyle(.roundedBorder)
                TextField("Second line (optional)", text: card.subtitle)
                    .textFieldStyle(.roundedBorder)

                // Font family picker — null (system default) plus a
                // curated shortlist of fonts that work well for title
                // cards. Menu-style rather than Picker so the bottom
                // of the list can include a "More Fonts…" action that
                // opens the full system font panel, letting the user
                // reach any font installed on their Mac.
                HStack {
                    Text("Font")
                    Spacer()
                    Menu {
                        ForEach(TitleCardFont.options) { option in
                            Button {
                                card.wrappedValue.fontName = option.familyName
                            } label: {
                                if card.wrappedValue.fontName == option.familyName {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                        Divider()
                        Button("More Fonts…") {
                            // Live callback — every change in the
                            // panel updates the card, so the user
                            // can preview fonts against the other
                            // card settings without closing the
                            // panel first.
                            TitleCardFontPanelBridge.shared.present(
                                currentFamily: card.wrappedValue.fontName
                            ) { newFamily in
                                card.wrappedValue.fontName = newFamily
                            }
                        }
                    } label: {
                        Text(cardFontMenuLabel(for: card.wrappedValue.fontName))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 220)
                }

                HStack {
                    ColorPicker("Text", selection: Binding(
                        get: { card.wrappedValue.textColor.swiftUIColor },
                        set: { card.wrappedValue.textColor = ColorRGBA(swiftUI: $0) }
                    ))
                    ColorPicker("Fill", selection: Binding(
                        get: { card.wrappedValue.backgroundColor.swiftUIColor },
                        set: { card.wrappedValue.backgroundColor = ColorRGBA(swiftUI: $0) }
                    ))
                }

                // Optional background image — when set, aspect-fills
                // over the background colour. Image file is copied
                // into Application Support so the original file can
                // move/rename/delete without breaking the card.
                cardImageControls(card: card)

                PlainSlider(
                    label: "Fade",
                    value: card.fadeDuration,
                    range: 0.5...4, low: "Quick", high: "Slow"
                )
            }
        }
    }

    @ViewBuilder
    private func cardImageControls(card: Binding<TitleCard>) -> some View {
        HStack(spacing: 8) {
            Text("Picture")
            if let filename = card.wrappedValue.backgroundImageFilename,
               !filename.isEmpty {
                // Small thumbnail so the user can confirm which image
                // is currently loaded. `NSImage(contentsOf:)` is a
                // synchronous disk read and was run on every inspector
                // render; cached by (UUID) filename instead.
                if let ns = TitleCardThumbnails.image(for: filename) {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 54, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    // File missing — surface that directly so the
                    // user knows the card will render with just the
                    // background colour.
                    Text("(image missing)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                chooseCardImage(for: card)
            } label: {
                Label(
                    card.wrappedValue.backgroundImageFilename == nil ? "Choose…" : "Replace…",
                    systemImage: "photo"
                )
            }
            .controlSize(.small)

            if card.wrappedValue.backgroundImageFilename != nil {
                Button(role: .destructive) {
                    if let old = card.wrappedValue.backgroundImageFilename {
                        TitleCardAssets.remove(filename: old)
                    }
                    card.wrappedValue.backgroundImageFilename = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Clear the background image — revert to solid colour")
            }
        }
    }

    /// Label shown on the font menu's button. Prefers the curated-
    /// list label when the family matches a known option; otherwise
    /// falls back to the raw family name (which is what `NSFontPanel`
    /// will have fed us). `nil` → "System".
    private func cardFontMenuLabel(for fontName: String?) -> String {
        if let match = TitleCardFont.options.first(where: { $0.familyName == fontName }) {
            return match.label
        }
        return fontName ?? "System"
    }

    /// Open an NSOpenPanel for image selection, copy into the assets
    /// directory, and update the card binding. Previously-stored
    /// image (if any) is removed so we don't accumulate stale files.
    private func chooseCardImage(for card: Binding<TitleCard>) {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let old = card.wrappedValue.backgroundImageFilename {
            TitleCardAssets.remove(filename: old)
        }
        if let stored = TitleCardAssets.store(copyingFrom: url) {
            card.wrappedValue.backgroundImageFilename = stored
        }
    }
}
