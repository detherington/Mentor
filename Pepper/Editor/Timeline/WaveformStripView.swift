import SwiftUI

/// Mic-amplitude strip drawn behind the trim track. Treats `samples`
/// (0...1 peak per bucket) as a symmetric silhouette around the vertical
/// centre. Empty samples array → blank view, so first-paint happens
/// before the async sampler finishes.
struct WaveformStripView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }
            let bucketCount = samples.count
            // Each bucket gets a vertical line ~1.5px wide with a small
            // gap. Works out to ~500 buckets visible at typical widths;
            // we downsample by stepping through `samples` if the window
            // is narrower than the sample count.
            let stride = max(1, Int(ceil(Double(bucketCount) / Double(size.width / 2))))
            let lineWidth: CGFloat = 1.5
            let midY = size.height / 2
            let halfHeight = size.height * 0.42  // leave small top/bottom padding

            var path = Path()
            var i = 0
            while i < bucketCount {
                let amp = CGFloat(samples[i])
                let x = size.width * (CGFloat(i) / CGFloat(bucketCount))
                let h = max(1, amp * halfHeight)
                path.move(to: CGPoint(x: x, y: midY - h))
                path.addLine(to: CGPoint(x: x, y: midY + h))
                i += stride
            }
            // Ink, not white: white vanished on the light-mode track.
            context.stroke(
                path,
                with: .color(.primary.opacity(0.7)),
                lineWidth: lineWidth
            )
        }
    }
}
