import AppKit
import CoreGraphics
import Foundation

/// Maps a global Cocoa screen point (the coordinate system stored in
/// `events.json` clicks) into image-pixel coordinates of the captured
/// source. Both smart zoom + cursor ripples need this; centralising it
/// keeps the (display | window | region) coordinate flips in one place.
///
/// Coordinate cheat-sheet:
///   - `NSEvent.mouseLocation` (events.json `x`/`y`):
///       Cocoa global, points, origin **bottom-left** of *primary* display.
///   - `NSScreen.frame`: Cocoa global, points, origin bottom-left of primary.
///   - `SCWindow.frame` (metadata.windowFrame*): Quartz, points,
///       origin **top-left** of primary display.
///   - Image pixels (what Core Image / our compositor want):
///       origin bottom-left of the captured image.
@MainActor
enum SourceCoordinateMapper {

    /// Translate `p` (global Cocoa screen point) into image-pixel
    /// coordinates for `metadata`'s captured source. Returns nil for
    /// clicks outside the captured area.
    static func imagePixel(
        forScreenPoint p: CGPoint,
        metadata: RecordingMetadata
    ) -> CGPoint? {
        let scale = CGFloat(metadata.backingScale ?? 2.0)

        switch metadata.source.kind {
        case "display":
            guard let displayID = metadata.source.displayID,
                  let screen = screen(forDisplayID: displayID) else {
                return nil
            }
            let frame = screen.frame
            guard frame.contains(p) else { return nil }
            let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
            return CGPoint(x: local.x * scale, y: local.y * scale)

        case "window":
            guard let wx = metadata.source.windowFrameX,
                  let wy = metadata.source.windowFrameY,
                  let ww = metadata.source.windowFrameWidth,
                  let wh = metadata.source.windowFrameHeight else {
                return nil
            }
            // Convert window frame from Quartz (top-left primary) to Cocoa
            // (bottom-left primary) via primary screen height.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let windowOriginCocoa = CGPoint(
                x: wx,
                y: primaryHeight - wy - wh
            )
            let windowFrameCocoa = CGRect(
                origin: windowOriginCocoa,
                size: CGSize(width: ww, height: wh)
            )
            guard windowFrameCocoa.contains(p) else { return nil }
            let local = CGPoint(
                x: p.x - windowFrameCocoa.minX,
                y: p.y - windowFrameCocoa.minY
            )
            return CGPoint(x: local.x * scale, y: local.y * scale)

        case "region":
            guard let displayID = metadata.source.displayID,
                  let screen = screen(forDisplayID: displayID),
                  let rx = metadata.source.regionX,
                  let ry = metadata.source.regionY,
                  let rw = metadata.source.regionWidth,
                  let rh = metadata.source.regionHeight else {
                return nil
            }
            let displayFrame = screen.frame
            guard displayFrame.contains(p) else { return nil }
            let localCocoa = CGPoint(
                x: p.x - displayFrame.minX,
                y: p.y - displayFrame.minY
            )
            // Region rect is Quartz (TL within display) — flip to Cocoa.
            let regionOriginCocoa = CGPoint(
                x: rx,
                y: displayFrame.height - ry - rh
            )
            let regionFrame = CGRect(
                origin: regionOriginCocoa,
                size: CGSize(width: rw, height: rh)
            )
            guard regionFrame.contains(localCocoa) else { return nil }
            let local = CGPoint(
                x: localCocoa.x - regionFrame.minX,
                y: localCocoa.y - regionFrame.minY
            )
            return CGPoint(x: local.x * scale, y: local.y * scale)

        default:
            return nil
        }
    }

    private static func screen(forDisplayID id: UInt32) -> NSScreen? {
        NSScreen.screens.first { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return n.uint32Value == id
        }
    }
}
