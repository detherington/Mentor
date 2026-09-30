import CoreGraphics
import CoreMedia
import Foundation

/// Walks the `events.json` click log and builds a `CursorRipple` for each
/// click whose screen position can be mapped into the captured image.
/// Same coordinate-mapping path as `ZoomKeyframeGenerator`, just with
/// looser filtering — every click gets a ripple, even ones too close to
/// the start/end of the recording (the compositor's "is this ripple still
/// active?" check naturally handles edge cases).
@MainActor
enum CursorRippleGenerator {

    static func generate(
        from log: EventRecorder.Log?,
        metadata: RecordingMetadata
    ) -> [CursorRipple] {
        guard let log else { return [] }

        var ripples: [CursorRipple] = []
        ripples.reserveCapacity(log.events.count)
        for evt in log.events where evt.type == "click" {
            guard let x = evt.x, let y = evt.y else { continue }
            guard let target = SourceCoordinateMapper.imagePixel(
                forScreenPoint: CGPoint(x: x, y: y),
                metadata: metadata
            ) else { continue }
            ripples.append(CursorRipple(
                time: CMTime(seconds: max(0, evt.t), preferredTimescale: 600),
                target: target
            ))
        }
        return ripples
    }
}
