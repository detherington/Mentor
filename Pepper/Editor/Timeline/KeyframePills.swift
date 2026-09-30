import SwiftUI
import AVFoundation

/// Common translator: how much time does `pixels` represent on a
/// `trackWidth`-wide track of `duration` seconds?
private func secondsFor(pixels: CGFloat, trackWidth: CGFloat, duration: CMTime) -> Double {
    guard trackWidth > 0 else { return 0 }
    let total = CMTimeGetSeconds(duration)
    guard total.isFinite, total > 0 else { return 0 }
    return Double(pixels / trackWidth) * total
}

/// A draggable keyframe pill on a timeline lane — zoom (purple) and
/// talking head (pink) used to be two copies of this differing only in
/// colour, height, tooltip and which view-model calls they made. Body
/// drag moves the whole keyframe, right-edge drag stretches the hold,
/// tap seeks to the peak.
///
/// `@State` captures the pre-drag baseline so successive onChanged
/// callbacks don't compound (translation applies to the original
/// start / hold end, not the already-moved one). Each pill instance has
/// its own baselines, so they never leak between lanes.
struct KeyframePill<K: RampKeyframe>: View {
    let viewModel: EditorViewModel
    let kf: K
    let trackWidth: CGFloat
    let height: CGFloat
    let color: Color
    let help: String
    let onMove: (_ id: UUID, _ newStart: CMTime) -> Void
    let onSetHold: (_ id: UUID, _ hold: CMTime) -> Void
    /// A click (not a drag): opens this keyframe's inspector row.
    var onSelect: (_ id: UUID) -> Void = { _ in }

    @State private var moveBaseline: CMTime?
    @State private var resizeBaseline: CMTime?

    private let resizeGrabWidth: CGFloat = 10

    var body: some View {
        let startX = xFor(kf.startTime)
        let endX   = xFor(kf.endTime)
        let w = max(2, endX - startX)

        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)

            // Right-edge resize grab — translucent darker strip. Wins
            // hit-testing over the body because it's later in the ZStack.
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: min(resizeGrabWidth, max(2, w - 4)), height: height)
                .gesture(resizeGesture)
        }
        .frame(width: w, height: height)
        .offset(x: startX)
        .help(help)
        .gesture(moveGesture)
        .onTapGesture {
            viewModel.seek(to: kf.peakStartTime)
            onSelect(kf.id)
        }
    }

    private var moveGesture: some Gesture {
        // 5px deadband so a click-intended-as-seek doesn't accidentally
        // move the pill by a pixel or two.
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if moveBaseline == nil { moveBaseline = kf.startTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                onMove(kf.id, CMTimeAdd(moveBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600)))
            }
            .onEnded { _ in moveBaseline = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeBaseline == nil { resizeBaseline = kf.holdEndTime }
                let dtSec = secondsFor(pixels: value.translation.width, trackWidth: trackWidth, duration: viewModel.duration)
                let newHoldEnd = CMTimeAdd(resizeBaseline!, CMTime(seconds: dtSec, preferredTimescale: 600))
                let holdStart = CMTimeAdd(kf.startTime, kf.inDuration)
                onSetHold(kf.id, CMTimeSubtract(newHoldEnd, holdStart))
            }
            .onEnded { _ in resizeBaseline = nil }
    }

    private func xFor(_ t: CMTime) -> CGFloat {
        TimelineMath.x(for: t, duration: viewModel.duration, width: trackWidth)
    }
}
