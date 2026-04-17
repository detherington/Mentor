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
}
