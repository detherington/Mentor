import AppKit
import SwiftUI

/// An error the way a person should read it: what happened and what to
/// do, in plain words. The technical text (an AVFoundation code, an HTTP
/// status) stays in `details`, behind Copy Details, for whoever fixes it.
/// Export and upload failures used to show it raw, e.g. "Final render
/// failed: reader.startReading: … (AVFoundationErrorDomain error -11841.)".
struct FriendlyError: Equatable {
    let title: String
    let advice: String
    let details: String

    init(title: String, advice: String, details: String) {
        self.title = title
        self.advice = advice
        self.details = details
    }

    init(_ error: Error) {
        let ns = error as NSError
        var details = error.localizedDescription
        if !(error is LocalizedError), !details.contains(ns.domain) {
            details += " (\(ns.domain) \(ns.code))"
        }
        self = Self.describe(error, details: details)
    }

    private static let passItOn = "If it keeps happening, use Copy Details to pass the error along."
    private static let outOfSpaceTitle = "Your Mac is out of space"

    var isOutOfSpace: Bool { title == Self.outOfSpaceTitle }

    private static func describe(_ error: Error, details: String) -> FriendlyError {
        if isOutOfSpace(error, details: details) {
            return FriendlyError(title: outOfSpaceTitle,
                                 advice: "Pepper couldn't save the video. Free up some space, then try again.",
                                 details: details)
        }
        switch error {
        case FinalRenderer.RenderError.cancelled:
            return FriendlyError(title: "Export cancelled", advice: "Nothing was saved.", details: details)
        case is FinalRenderer.RenderError:
            return FriendlyError(title: "Pepper couldn't make the video",
                                 advice: "Close the recording, open it again, and try once more. \(passItOn)",
                                 details: details)
        case let orbis as OrbisError:
            return describe(orbis, details: details)
        case is URLError:
            return network(details)
        default:
            return FriendlyError(title: "Something went wrong", advice: "Try again. \(passItOn)", details: details)
        }
    }

    private static func describe(_ error: OrbisError, details: String) -> FriendlyError {
        switch error {
        case .networkError:
            return network(details)
        case .serverError(let status, _) where status >= 500:
            return FriendlyError(title: "Orbis had a problem",
                                 advice: "Orbis couldn't take the video just now. Try again in a few minutes.",
                                 details: details)
        case .serverError:
            return FriendlyError(title: "Orbis didn't accept the video", advice: "Try again. \(passItOn)", details: details)
        case .decodingError:
            return FriendlyError(title: "Orbis replied in a way Pepper didn't expect",
                                 advice: "Pepper may need updating: choose Pepper › Check for Updates…, then try again.",
                                 details: details)
        case .tokenMissing, .tokenInvalid, .oauthRejected, .signInFailed:
            return FriendlyError(title: "You're signed out of Orbis",
                                 advice: "Sign in again in Settings › Orbis, then try again.",
                                 details: details)
        case .permissionDenied, .tooLarge, .uploadURLExpired, .invalidHost:
            // These already say what to do.
            return FriendlyError(title: "Orbis didn't accept the video", advice: error.localizedDescription, details: details)
        }
    }

    private static func network(_ details: String) -> FriendlyError {
        FriendlyError(title: "Pepper couldn't reach Orbis",
                      advice: "Check your internet connection, then try again.",
                      details: details)
    }

    /// Disk full, however it surfaces: Cocoa, POSIX, or AVFoundation's
    /// -11807 (often only in a render error's text).
    private static func isOutOfSpace(_ error: Error, details: String) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        return details.contains("-11807") || details.localizedCaseInsensitiveContains("no space left")
    }

    func copyDetails() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }
}

/// A failure in a sheet: what happened, what to do, and Copy Details.
struct FriendlyErrorView: View {
    let error: FriendlyError
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(error.title).font(.headline)
                Text(error.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied ? "Details Copied" : "Copy Details") {
                    error.copyDetails()
                    copied = true
                }
                .buttonStyle(.link)
                .font(.caption)
                .help(error.details)
            }
            Spacer(minLength: 0)
        }
    }
}
