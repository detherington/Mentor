import Foundation
import AVFoundation
import AppKit
import Observation

/// Orchestrates a full "Export to Orbis" flow for a single recording:
///   1. FinalRenderer → temp .mp4 (the user's current editor state).
///   2. Optional: build thumbnail + transcript payload.
///   3. POST /api/videos (reserve row, get presigned PUT URL).
///   4. PUT the .mp4 to R2 (with progress).
///   5. POST /api/videos/<id>/ingest-assets (best-effort, 404-tolerant).
///   6. PATCH /api/videos/<id>/complete.
///
/// The UI (`OrbisExportSheet`) observes `phase`, `progress`, and
/// `error` to render its banner / progress bar / success state.
/// One controller per export — throw it away after the flow ends.
@MainActor
@Observable
final class OrbisExportController {
    enum Phase: Equatable {
        case idle
        case preparing
        case rendering
        case reserving
        case uploading
        case ingesting
        case completing
        case finished(videoID: String)
        case failed(message: String)
    }

    /// Form inputs captured from the sheet before we start.
    struct Request {
        let title: String
        let description: String?
        let visibility: OrbisVisibility
        let clientID: String?
        let includeAssets: Bool
        let layout: FinalRenderer.ExportLayout
        let trimMap: TrimMap?
        let bundle: RecordingBundle
        let metadata: RecordingMetadata
        let transcription: TranscriptionLog?
        let recordedAt: Date?
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    /// Fills in after the first successful POST /api/videos so the
    /// sheet can show a "View in Orbis" link as soon as the video
    /// row exists, even if the upload's still in flight.
    private(set) var videoID: String?

    private var task: Task<Void, Never>?
    private var tempOutputURL: URL?

    // Progress is segmented across the phases so the UI sees a
    // monotonic 0→1 bar instead of resetting per step.
    private struct Segment {
        let phase: Phase
        let weight: Double  // fraction of total
    }
    private let segments: [Segment] = [
        .init(phase: .preparing,  weight: 0.02),
        .init(phase: .rendering,  weight: 0.55),
        .init(phase: .reserving,  weight: 0.02),
        .init(phase: .uploading,  weight: 0.30),
        .init(phase: .ingesting,  weight: 0.05),
        .init(phase: .completing, weight: 0.06),
    ]

    // MARK: - Public API

    func start(_ request: Request) {
        guard task == nil else { return }
        phase = .preparing
        progress = 0
        videoID = nil

        task = Task { [weak self] in
            await self?.run(request)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        cleanupTemp()
    }

    // MARK: - Flow

    private func run(_ request: Request) async {
        defer { cleanupTemp() }

        // 1. Auth check. Keychain might have been wiped between
        // sheet open and upload click; surface that immediately
        // rather than failing mid-render.
        guard let token = OrbisKeychain.loadToken() else {
            fail(OrbisError.tokenMissing)
            return
        }
        let client = OrbisClient(host: OrbisSettings.shared.host, token: token)
        setSegment(.preparing, within: 1.0)

        // 2. Render the current editor state to a temp MP4. Mirrors
        // the user's live preview — trim, keyframes, webcam, the
        // works — so what ships to Orbis matches what the user
        // sees.
        phase = .rendering
        let renderedURL: URL
        do {
            renderedURL = try await renderToTemp(request: request)
            tempOutputURL = renderedURL
        } catch {
            fail(error)
            return
        }
        if Task.isCancelled { return }

        // 3. Reserve + get R2 PUT URL.
        phase = .reserving
        setSegment(.reserving, within: 1.0)
        let sizeBytes: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: renderedURL.path)
            sizeBytes = (attrs[.size] as? Int64) ?? 0
        } catch {
            fail(error)
            return
        }
        guard sizeBytes > 0 else {
            fail(OrbisError.serverError(status: 0, body: "Rendered MP4 is empty."))
            return
        }
        if sizeBytes > orbisMaxUploadBytes {
            fail(OrbisError.tooLarge(limitBytes: orbisMaxUploadBytes))
            return
        }

        let reservation: OrbisCreateUploadResponse
        do {
            reservation = try await client.createUpload(
                title: request.title,
                description: request.description,
                visibility: request.visibility,
                clientID: request.clientID,
                mimeType: "video/mp4",
                sizeBytes: sizeBytes,
                recordedAt: request.recordedAt
            )
        } catch {
            fail(error)
            return
        }
        videoID = reservation.video_id
        if Task.isCancelled { return }

        // 4. PUT to R2. Progress reports 0→1 within the segment.
        phase = .uploading
        guard let remoteURL = URL(string: reservation.upload_url) else {
            fail(OrbisError.invalidHost(reservation.upload_url))
            return
        }
        do {
            try await client.uploadFile(from: renderedURL, to: remoteURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.setSegment(.uploading, within: fraction)
                }
            }
        } catch OrbisError.uploadURLExpired {
            // Spec: URL expired between reservation and PUT.
            // Reserve a new URL and retry once. If that also fails,
            // surface to the user.
            do {
                let retry = try await client.createUpload(
                    title: request.title,
                    description: request.description,
                    visibility: request.visibility,
                    clientID: request.clientID,
                    mimeType: "video/mp4",
                    sizeBytes: sizeBytes,
                    recordedAt: request.recordedAt
                )
                videoID = retry.video_id
                guard let retryURL = URL(string: retry.upload_url) else {
                    fail(OrbisError.invalidHost(retry.upload_url))
                    return
                }
                try await client.uploadFile(from: renderedURL, to: retryURL) { [weak self] fraction in
                    Task { @MainActor in
                        self?.setSegment(.uploading, within: fraction)
                    }
                }
            } catch {
                fail(error)
                return
            }
        } catch {
            fail(error)
            return
        }
        if Task.isCancelled { return }

        // 5. Optional: ingest-assets. Best-effort per spec — a 404
        // from an un-deployed endpoint or a thumbnail encode failure
        // shouldn't block Step C. Log + move on.
        phase = .ingesting
        setSegment(.ingesting, within: 0.0)
        if request.includeAssets {
            let assets = await buildAssetsPayload(
                bundle: request.bundle,
                metadata: request.metadata,
                transcription: request.transcription,
                renderedURL: renderedURL
            )
            do {
                _ = try await client.ingestAssets(videoID: reservation.video_id, payload: assets)
            } catch {
                MentorDebug.log("ORBIS: ingest-assets failed (continuing): \(error.localizedDescription)")
            }
        }
        setSegment(.ingesting, within: 1.0)
        if Task.isCancelled { return }

        // 6. Tell Orbis we're done. From here, the server runs its
        // own pipeline (thumbnail/transcript/summary for any stage
        // we didn't pre-compute).
        phase = .completing
        setSegment(.completing, within: 0.5)
        do {
            try await client.completeUpload(videoID: reservation.video_id)
        } catch {
            fail(error)
            return
        }
        setSegment(.completing, within: 1.0)
        phase = .finished(videoID: reservation.video_id)
        progress = 1.0
        task = nil
    }

    // MARK: - Render

    private func renderToTemp(request: Request) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mentor-Orbis", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).mp4"
        let outputURL = tempDir.appendingPathComponent(name)

        return try await FinalRenderer.render(
            bundle: request.bundle,
            metadata: request.metadata,
            layout: request.layout,
            trimMap: request.trimMap,
            outputURL: outputURL
        ) { [weak self] fraction in
            // FinalRenderer emits Float [0, 1]; our segment helper
            // takes Double.
            let asDouble = Double(fraction)
            Task { @MainActor in
                self?.setSegment(.rendering, within: asDouble)
            }
        }
    }

    // MARK: - Assets

    /// Build the optional `ingest-assets` payload. Always sets
    /// duration; includes the thumbnail if we can render one and the
    /// transcript if the bundle has one. Skips summary/chapters —
    /// Mentor doesn't produce either today.
    private func buildAssetsPayload(
        bundle: RecordingBundle,
        metadata: RecordingMetadata,
        transcription: TranscriptionLog?,
        renderedURL: URL
    ) async -> OrbisIngestAssets {
        var payload = OrbisIngestAssets()

        // Duration: prefer the AVAsset's actual duration (matches the
        // uploaded file) over metadata guesses.
        let asset = AVURLAsset(url: renderedURL)
        if let d = try? await asset.load(.duration), d.seconds.isFinite {
            payload.duration_seconds = Int(d.seconds.rounded())
        }

        if let t = transcription {
            let utterances = t.lines.map { line in
                OrbisIngestAssets.Utterance(
                    start: Int((line.startSeconds * 1000).rounded()),
                    end:   Int((line.endSeconds   * 1000).rounded()),
                    speaker: nil,
                    text: line.text
                )
            }
            let flatText = t.lines.map(\.text).joined(separator: " ")
            payload.transcript = .init(text: flatText, utterances: utterances)
        }

        if let thumb = await renderThumbnail(from: renderedURL) {
            payload.thumbnail_base64 = thumb
        }

        return payload
    }

    /// Grab a representative frame from the rendered MP4, scale to
    /// 640x360, JPEG-encode at 80% quality, base64-encode. Returns
    /// nil if any step fails — thumbnails are optional.
    private func renderThumbnail(from url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let jpeg = bitmap.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.8]
            ) else { return nil }
            return jpeg.base64EncodedString()
        } catch {
            MentorDebug.log("ORBIS: thumbnail generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Phase / progress helpers

    /// Within-segment fraction in [0, 1] — updates the overall
    /// `progress` field by summing the weights of prior segments
    /// plus the current segment's fractional weight.
    private func setSegment(_ segPhase: Phase, within fraction: Double) {
        var total: Double = 0
        for seg in segments {
            if seg.phase == segPhase {
                total += seg.weight * max(0, min(1, fraction))
                break
            }
            total += seg.weight
        }
        progress = total
    }

    private func fail(_ error: Error) {
        let message: String
        if let orbis = error as? OrbisError {
            message = orbis.localizedDescription
        } else {
            message = error.localizedDescription
        }
        phase = .failed(message: message)
        task = nil
    }

    private func cleanupTemp() {
        guard let url = tempOutputURL else { return }
        try? FileManager.default.removeItem(at: url)
        tempOutputURL = nil
    }
}
