import CoreGraphics
import CoreImage
import Foundation
import AppKit

/// Compositor-ready sequence of cursor positions in image-pixel coords.
/// Built from `CursorSampler.Log` via `CursorHighlightTrack.make(...)`;
/// the compositor does a binary search + linear interpolate into this
/// array once per frame.
struct CursorHighlightTrack: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let t: TimeInterval   // seconds from recording start
        let x: Double         // image-pixel coords, bottom-left origin
        let y: Double
    }
    let points: [Point]

    static let empty = CursorHighlightTrack(points: [])

    /// Translate the sampler's raw screen-coord samples into the same
    /// image-pixel coordinate space the screen track uses. Samples
    /// that fall outside the captured area (e.g. cursor on a different
    /// monitor for a moment) are dropped.
    @MainActor
    static func make(from log: CursorSampler.Log?, metadata: RecordingMetadata) -> CursorHighlightTrack {
        guard let log else { return .empty }
        var out: [Point] = []
        out.reserveCapacity(log.samples.count)
        for s in log.samples {
            guard let p = SourceCoordinateMapper.imagePixel(
                forScreenPoint: CGPoint(x: s.x, y: s.y),
                metadata: metadata
            ) else { continue }
            out.append(Point(t: s.t, x: Double(p.x), y: Double(p.y)))
        }
        return CursorHighlightTrack(points: out)
    }

    /// Look up the interpolated cursor position at `tSeconds`.
    /// Returns nil if `tSeconds` is before the first sample, after the
    /// last, or if the track is empty. Nil-returning lets the
    /// compositor skip the render when there's no data.
    func position(at tSeconds: Double) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        if tSeconds < points.first!.t { return nil }
        if tSeconds > points.last!.t  { return nil }

        // Binary search for the straddling pair.
        var lo = 0
        var hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].t <= tSeconds { lo = mid } else { hi = mid - 1 }
        }
        let i = lo
        let a = points[i]
        if i == points.count - 1 {
            return CGPoint(x: a.x, y: a.y)
        }
        let b = points[i + 1]
        let span = b.t - a.t
        guard span > 0 else { return CGPoint(x: a.x, y: a.y) }
        let frac = (tSeconds - a.t) / span
        return CGPoint(
            x: a.x + (b.x - a.x) * frac,
            y: a.y + (b.y - a.y) * frac
        )
    }
}

/// Styling for the always-on cursor highlight. Separate from the
/// click-ripple style so the user can enable one, both, or neither.
struct CursorHighlightStyle: Codable, Equatable, Sendable {
    /// Master on/off.
    var enabled: Bool
    /// Radius of the halo in image pixels (at capture resolution).
    /// Rendered as a soft radial gradient so the edge is feathered.
    var radius: CGFloat
    /// Peak opacity at the centre. Tapers to 0 at `radius`.
    var opacity: CGFloat
    /// Tint of the halo. RGBA 0–1.
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let `default` = CursorHighlightStyle(
        enabled: false,
        radius: 60,
        opacity: 0.55,
        red: 1.0,
        green: 0.85,
        blue: 0.15
    )
}

/// Draws a soft radial-gradient halo at the cursor position. The
/// compositor calls this once per frame when the highlight is active.
/// Rasterised into a CGContext of just the halo's bounding box (keeps
/// the render cheap — we don't touch pixels outside the halo).
enum CursorHighlightRenderer {
    /// Returns a CIImage sized `2*radius × 2*radius`, translated so
    /// the halo is centred at `center`. Caller composites directly
    /// over the base frame.
    static func render(
        center: CGPoint,
        style: CursorHighlightStyle
    ) -> CIImage? {
        let radius = style.radius
        guard radius > 1, style.opacity > 0 else { return nil }
        let side = Int(ceil(radius * 2))
        guard side > 0 else { return nil }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Radial gradient: solid tint at the centre, fully transparent
        // at the edge. Three stops so the falloff reads softly without
        // a hard inner ring.
        let colors = [
            CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: style.opacity),
            CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: style.opacity * 0.55),
            CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 0)
        ] as CFArray
        let stops: [CGFloat] = [0.0, 0.6, 1.0]
        guard let gradient = CGGradient(
            colorsSpace: space,
            colors: colors,
            locations: stops
        ) else { return nil }

        let centre = CGPoint(x: radius, y: radius)
        ctx.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: 0,
            endCenter: centre,
            endRadius: radius,
            options: []
        )

        guard let cg = ctx.makeImage() else { return nil }
        // Shift so the halo's centre lands at `center` in the output.
        return CIImage(cgImage: cg)
            .transformed(by: CGAffineTransform(translationX: center.x - radius, y: center.y - radius))
    }
}
