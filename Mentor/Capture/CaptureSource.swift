import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureSource {
    case display(SCDisplay)
    case window(SCWindow)
    case region(display: SCDisplay, rect: CGRect)

    var displayName: String {
        switch self {
        case .display(let d):
            return "Display \(d.displayID) (\(d.width) × \(d.height))"
        case .window(let w):
            let app = w.owningApplication?.applicationName ?? "Window"
            let title = (w.title?.isEmpty == false) ? " — \(w.title!)" : ""
            return "\(app)\(title)"
        case .region(_, let rect):
            return "Region (\(Int(rect.width)) × \(Int(rect.height)))"
        }
    }

    func makeFilter() -> SCContentFilter {
        switch self {
        case .display(let d):
            return SCContentFilter(display: d, excludingWindows: [])
        case .window(let w):
            return SCContentFilter(desktopIndependentWindow: w)
        case .region(let d, _):
            return SCContentFilter(display: d, excludingWindows: [])
        }
    }

    /// Output frame size in pixels, accounting for backing scale.
    func pixelSize(scale: CGFloat) -> CGSize {
        switch self {
        case .display(let d):
            return CGSize(
                width: CGFloat(d.width) * scale,
                height: CGFloat(d.height) * scale
            )
        case .window(let w):
            return CGSize(
                width: w.frame.width * scale,
                height: w.frame.height * scale
            )
        case .region(_, let rect):
            return CGSize(
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
    }

    /// Sub-rect of the source to capture (in points, display-relative).
    /// Only used for region capture.
    var sourceRect: CGRect? {
        if case .region(_, let rect) = self { return rect }
        return nil
    }

    /// Backing scale factor for the display this source lives on. We
    /// can't use `NSScreen.main` — that's whichever screen owns the key
    /// window, which on multi-monitor setups may be a different display
    /// than the one being captured (mismatched scales → wrong pixel
    /// dimensions → AVAssetWriterInput rejecting the output settings).
    @MainActor
    func backingScale() -> CGFloat {
        switch self {
        case .display(let d), .region(let d, _):
            if let screen = Self.screen(forDisplayID: d.displayID) {
                return screen.backingScaleFactor
            }
        case .window(let w):
            // `SCWindow.frame` is in Quartz (window-server, top-left
            // origin) coordinates while `NSScreen.frame.contains` wants
            // AppKit (bottom-left origin). Testing a Quartz point
            // against AppKit screen frames quietly misses on
            // non-primary displays — the window "belongs" nowhere and
            // we fall through to `NSScreen.main`.
            let appkitFrame = Self.convertQuartzToAppKit(w.frame)
            let center = CGPoint(x: appkitFrame.midX, y: appkitFrame.midY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    /// Output size in pixels for recording. Snaps to even dimensions —
    /// H.264's 4:2:0 chroma subsampling requires even width/height and
    /// `AVAssetWriterInput` throws an uncatchable NSInvalidArgument if
    /// it gets an odd value. Also clamps to `Self.maxEncodeDimension`
    /// preserving aspect — Apple Silicon's H.264 hardware encoder caps
    /// at roughly 4K on the long side and rejects anything larger with
    /// another uncatchable exception (hit in the wild on 5K/6K
    /// external displays). Returns nil if the source reports a
    /// zero-area rect (e.g. a window that was closed between picking
    /// and starting).
    @MainActor
    func outputPixelSize() -> CGSize? {
        let raw = pixelSize(scale: backingScale())
        guard raw.width > 0, raw.height > 0 else { return nil }

        let longSide = max(raw.width, raw.height)
        let scale = longSide > CGFloat(Self.maxEncodeDimension)
            ? CGFloat(Self.maxEncodeDimension) / longSide
            : 1.0

        let width = Int((raw.width * scale).rounded(.down)) & ~1
        let height = Int((raw.height * scale).rounded(.down)) & ~1
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Conservative cap matching Apple Silicon H.264 hardware encoder
    /// limits (≈4K on the long side). Going larger hits an uncatchable
    /// NSInvalidArgument from `AVAssetWriterInput` at init time.
    static let maxEncodeDimension = 3840

    /// The NSScreen hosting this source — used by the countdown
    /// overlay and recording border so they appear on the display the
    /// user's capturing, not wherever the menu bar happens to live.
    /// For windows, picks the screen the window most overlaps.
    @MainActor
    func targetScreen() -> NSScreen? {
        switch self {
        case .display(let d), .region(let d, _):
            return Self.screen(forDisplayID: d.displayID)
        case .window(let w):
            // Convert the window-server (top-left origin) frame into
            // AppKit (bottom-left origin) before comparing against
            // NSScreen.frame. Without this the intersection is zero on
            // every non-primary screen and `.max` returns whichever
            // screen sorted first — i.e. main.
            let appkitFrame = Self.convertQuartzToAppKit(w.frame)
            return NSScreen.screens.max { a, b in
                Self.intersectionArea(a.frame, appkitFrame) <
                    Self.intersectionArea(b.frame, appkitFrame)
            }
        }
    }

    /// Flip Y to convert a Quartz (top-left origin, shared with
    /// `CGWindow` / `SCWindow`) rect into AppKit (bottom-left origin,
    /// shared with `NSScreen`). The anchor is the screen at AppKit
    /// origin (0, 0) — the primary display, which owns the menu bar.
    @MainActor
    private static func convertQuartzToAppKit(_ rect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        guard !r.isNull, !r.isEmpty else { return 0 }
        return r.width * r.height
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }
}
