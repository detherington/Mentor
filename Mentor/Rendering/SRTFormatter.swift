import Foundation

/// SubRip (`.srt`) formatter. The format is plain-text with numbered
/// blocks separated by blank lines:
///
/// ```
/// 1
/// 00:00:00,500 --> 00:00:03,200
/// Hello, this is a test.
///
/// 2
/// 00:00:03,500 --> 00:00:06,800
/// Another caption line.
/// ```
///
/// Every serious video tool (YouTube, Vimeo, Premiere, Final Cut,
/// DaVinci, VLC) accepts this. We emit CRLF line endings because the
/// original SubRip parser on Windows expects them, and modern tools
/// don't care either way — safer to write the stricter variant.
enum SRTFormatter {
    /// Render a list of caption lines into an SRT document. Lines are
    /// emitted in the order given. Times are expected in "output"
    /// time (i.e. already remapped through the TrimMap so they match
    /// the exported MP4's timeline, not the raw recording's).
    static func format(lines: [TranscriptionLine]) -> String {
        var out = ""
        for (idx, line) in lines.enumerated() {
            out += "\(idx + 1)\r\n"
            out += "\(formatTime(line.startSeconds)) --> \(formatTime(line.endSeconds))\r\n"
            out += "\(line.text)\r\n"
            out += "\r\n"
        }
        return out
    }

    /// Format a seconds value as the SRT timestamp `HH:MM:SS,mmm`.
    /// Note the comma (not period) before the millisecond component —
    /// SubRip's convention, and strict parsers reject the dot form.
    private static func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00:00,000" }
        let totalMs = Int((t * 1000).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
