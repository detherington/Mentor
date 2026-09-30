import Foundation
import CoreGraphics

/// Persisted alongside each recording so the editor can reconstruct the
/// original capture context (source dimensions, webcam layout, etc.).
struct RecordingMetadata: Codable {
    let version: Int
    let startDate: Date
    let source: SourceInfo
    let screenPixelSize: CGSizeCodable
    let webcamPixelSize: CGSizeCodable
    let compositedPixelSize: CGSizeCodable
    let webcamLayout: WebcamLayoutInfo
    let hasSystemAudio: Bool
    /// Backing scale of the display at recording time (1.0 / 2.0 / 2.52 …).
    /// Lets the editor convert `webcamLayout.diameterPoints` into output pixels.
    /// Optional for backward compatibility with pre–Phase 3b.2 bundles.
    let backingScale: Double?

    struct SourceInfo: Codable {
        let kind: String              // "display" / "window" / "region"
        let displayID: UInt32?        // when kind == display or region
        let windowID: UInt32?         // when kind == window
        let windowTitle: String?
        let appBundleID: String?
        let regionX: Double?
        let regionY: Double?
        let regionWidth: Double?
        let regionHeight: Double?
        /// Window frame at recording start, in **Quartz** screen points
        /// (origin top-left of primary display). Only populated for
        /// `kind == "window"`. Used by smart-zoom click → image-pixel
        /// mapping. Optional for backward compatibility with pre–Phase 4
        /// bundles.
        let windowFrameX: Double?
        let windowFrameY: Double?
        let windowFrameWidth: Double?
        let windowFrameHeight: Double?
        /// Captured display's frame at recording start, in **Cocoa**
        /// global points (origin bottom-left of the primary display).
        /// Populated for `display` / `region`. Lets the editor map clicks
        /// with the layout that was live while recording instead of
        /// whatever the displays look like now — rearranged or unplugged
        /// displays used to put zooms / ripples in the wrong place or drop
        /// them. Optional: older bundles fall back to the live NSScreen.
        let displayFrameX: Double?
        let displayFrameY: Double?
        let displayFrameWidth: Double?
        let displayFrameHeight: Double?
        /// Primary display height at recording start (points) — the
        /// Quartz → Cocoa flip for `windowFrame*`. Optional, as above.
        let primaryScreenHeight: Double?
    }

    struct WebcamLayoutInfo: Codable {
        let position: String          // WebcamPosition.rawValue
        let shape: String             // WebcamShape.rawValue
        let diameterPoints: Double
        let insetPoints: Double
    }

    struct CGSizeCodable: Codable {
        let width: Double
        let height: Double
        init(_ size: CGSize) {
            self.width = Double(size.width)
            self.height = Double(size.height)
        }
    }
}
