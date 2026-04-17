import Foundation

/// Writes to /tmp/mentor-debug.log so we can inspect output even when the
/// unified logging system redacts NSLog messages as <private>.
enum MentorDebug {
    static let logURL = URL(fileURLWithPath: "/tmp/mentor-debug.log")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        try? "".data(using: .utf8)?.write(to: logURL)
    }
}
