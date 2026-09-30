import Foundation

/// Writes to ~/Library/Logs/Mentor/mentor-debug.log so we can inspect
/// output even when the unified logging system redacts NSLog messages as
/// <private>. Console.app lists it under Log Reports.
///
/// Not /tmp: that path was world-readable and predictable, and `reset()`
/// wrote through whatever sat there — another local account could plant a
/// symlink and have Mentor truncate a file of its choosing, or simply read
/// the log (window titles, file paths). The user's Library is private to
/// them, the file is created owner-only, and it's never opened through a
/// symlink.
enum MentorDebug {
    static let logURL: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = library.appendingPathComponent("Logs/Mentor", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("mentor-debug.log")
    }()
    private static let lock = NSLock()
    /// Kept open between lines — reopening the file for every line was
    /// needless syscalls on paths that log from capture queues. Guarded
    /// by `lock`.
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if handle == nil { handle = open(truncating: false) }
        _ = try? handle?.write(contentsOf: data)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _ = try? handle?.close()
        handle = open(truncating: true)
    }

    private static func open(truncating: Bool) -> FileHandle? {
        // O_APPEND keeps concurrent writers (a duplicate instance quitting
        // at launch) from clobbering each other; O_NOFOLLOW refuses a
        // symlink planted at the log path.
        var flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        if truncating { flags |= O_TRUNC }
        let fd = Darwin.open(logURL.path, flags, 0o600)
        guard fd >= 0 else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
