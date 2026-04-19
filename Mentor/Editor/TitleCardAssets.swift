import AppKit
import Foundation

/// Manages user-supplied title-card background images. Each image is
/// copied into `~/Library/Application Support/Mentor/TitleCards/`
/// under a UUID-based filename so the title card's JSON settings can
/// reference it stably — renaming or deleting the user's original
/// doesn't orphan the card's background.
///
/// Images are stored at their original resolution + format (PNG/JPEG
/// detected from extension). The renderer handles aspect-fill scaling
/// at draw time, so we don't need to resize here.
enum TitleCardAssets {
    /// Base directory for card image files. Created on first access.
    static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base
            .appendingPathComponent("Mentor", isDirectory: true)
            .appendingPathComponent("TitleCards", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the absolute URL for a stored card image. Use this
    /// together with the filename stored in `TitleCard` to load the
    /// image at render time.
    static func url(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    /// Copy a user-chosen file into the assets directory and return
    /// the generated filename (including extension). Preserves the
    /// original extension so AppKit's `NSImage(contentsOf:)` can
    /// pick the right decoder. Nil on any I/O failure — caller should
    /// leave the card's old image in place.
    static func store(copyingFrom source: URL) -> String? {
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        let filename = "\(UUID().uuidString).\(ext.lowercased())"
        let dest = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            return nil
        }
        return filename
    }

    /// Remove a stored image from the assets directory. Idempotent —
    /// silently ignores missing files so callers can "clear" a card
    /// even if the image was never saved (e.g. broken reference).
    static func remove(filename: String) {
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
