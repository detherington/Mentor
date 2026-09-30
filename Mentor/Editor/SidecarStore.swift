import Foundation

/// Debounced writing of an editor's sidecar files. Each file is written
/// once its edits settle — pill drags, slider ticks and caption typing
/// used to re-encode and write JSON on the main thread on every tick.
///
/// A file's `contents` closure runs at write time, so the latest state
/// wins. It returns the bytes to write, nil to remove the file, or throws
/// to skip this write (logged) — an encoding failure must never turn into
/// a deleted file. The pending closure holds its owner until the write
/// happens, so a debounce in flight still lands after the window closes;
/// `flush()` writes everything pending immediately (close, quit).
@MainActor
final class SidecarStore {
    typealias Contents = () throws -> Data?

    private var pending: [URL: (task: Task<Void, Never>, contents: Contents)] = [:]

    func schedule(_ url: URL, after delay: Duration = .milliseconds(400), contents: @escaping Contents) {
        pending[url]?.task.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self,
                  let entry = self.pending.removeValue(forKey: url) else { return }
            Self.write(entry.contents, to: url)
        }
        pending[url] = (task, contents)
    }

    /// Write now, superseding any pending debounce for `url`.
    func writeNow(_ url: URL, contents: Contents) {
        pending.removeValue(forKey: url)?.task.cancel()
        Self.write(contents, to: url)
    }

    func flush() {
        let all = pending
        pending.removeAll()
        for (url, entry) in all {
            entry.task.cancel()
            Self.write(entry.contents, to: url)
        }
    }

    /// Pretty-printed, key-sorted JSON, so sidecars diff cleanly.
    static func json<T: Encodable>(
        _ value: T,
        dates: JSONEncoder.DateEncodingStrategy = .deferredToDate
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = dates
        return try encoder.encode(value)
    }

    private static func write(_ contents: Contents, to url: URL) {
        do {
            if let data = try contents() {
                try data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            MentorDebug.log("EDITOR: couldn't save \(url.lastPathComponent): \(error)")
        }
    }
}
