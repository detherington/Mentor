import SwiftUI
import AVFoundation

// Small views and helpers shared by the editor's inspector sections and
// timeline.

struct LabeledRow: View {
    let label: String
    let value: String
    init(_ label: String, value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline)
    }
}

/// An "add at playhead" button. Its own view because its enabled state
/// reads the playhead — see the note on the timeline's playhead views.
struct PlayheadGatedButton: View {
    let title: String
    let help: String
    let isEnabled: () -> Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
        }
        .controlSize(.small)
        .disabled(!isEnabled())
        .help(help)
    }
}

enum TimelineMath {
    static func timeString(_ t: CMTime) -> String {
        let seconds = CMTimeGetSeconds(t)
        guard seconds.isFinite, !seconds.isNaN else { return "--:--.-" }
        let totalMs = Int(max(0, seconds) * 10)
        let tenths = totalMs % 10
        let totalSec = totalMs / 10
        let m = totalSec / 60
        let s = totalSec % 60
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    static func x(for time: CMTime, duration: CMTime, width: CGFloat) -> CGFloat {
        let total = CMTimeGetSeconds(duration)
        guard total > 0, time.isValid, !time.isIndefinite else { return 0 }
        return CGFloat(max(0, min(1, CMTimeGetSeconds(time) / total))) * width
    }
}
