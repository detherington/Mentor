import Foundation

/// Types shared across the Orbis integration — API request / response
/// shapes, visibility enum, typed errors. Kept in one file because
/// they're all tightly coupled to the Orbis REST contract and change
/// together if the server evolves.

enum OrbisVisibility: String, CaseIterable, Identifiable, Codable, Sendable {
    case privateVisibility = "private"
    case team
    case client
    case publicVisibility = "public"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .privateVisibility: return "Private"
        case .team:              return "Team"
        case .client:            return "Client"
        case .publicVisibility:  return "Public"
        }
    }
}

struct OrbisUser: Codable, Sendable {
    let id: String
    let email: String?
    let name: String?
    let role: String?
}

/// Returned by `GET /api/clients`. Separate name from `OrbisClient`
/// (the API class) to avoid the "Clients use the OrbisClient to list
/// OrbisClients" head-scratcher.
struct OrbisClientInfo: Codable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// Response from `POST /api/videos`.
struct OrbisCreateUploadResponse: Codable, Sendable {
    let video_id: String
    let upload_url: String
    let upload_expires_at: String
    let storage_key: String
    let upload_source: String
}

/// Payload passed to `POST /api/videos/<id>/ingest-assets`. All fields
/// optional — Orbis re-runs its own pipeline for any stage we don't
/// pre-compute.
struct OrbisIngestAssets: Codable, Sendable {
    struct Utterance: Codable, Sendable {
        let start: Int     // ms
        let end: Int       // ms
        let speaker: String?
        let text: String
    }
    struct Transcript: Codable, Sendable {
        let text: String
        let utterances: [Utterance]
    }
    struct Chapter: Codable, Sendable {
        let start: Int     // seconds
        let title: String
    }

    var duration_seconds: Int?
    var thumbnail_base64: String?      // JPEG as base64 (no data URI prefix)
    var thumbnail_url: String?
    var transcript: Transcript?
    var ai_summary: String?
    var ai_chapters: [Chapter]?
}

struct OrbisIngestAssetsResponse: Codable, Sendable {
    let ok: Bool
    let skipped_stages: [String]?
}

/// Typed errors raised by `OrbisClient`. All other call sites treat
/// `OrbisError.tokenInvalid` as "prompt re-auth" and everything else
/// as "retry or surface the message".
enum OrbisError: LocalizedError, Sendable {
    case tokenMissing
    case tokenInvalid                           // 401
    case permissionDenied                       // 403 on Orbis API (not R2)
    case tooLarge(limitBytes: Int64)            // 413 or precheck
    case uploadURLExpired                       // 403 from R2 PUT
    case networkError(URLError)
    case serverError(status: Int, body: String?)
    case decodingError(Error)
    case invalidHost(String)

    var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Not connected to Orbis. Connect in Settings first."
        case .tokenInvalid:
            return "Your Orbis session expired. Please reconnect in Settings."
        case .permissionDenied:
            return "Your Orbis account doesn't have upload permission. Ask an Orbis admin."
        case .tooLarge(let limit):
            let gb = Double(limit) / 1_073_741_824
            return String(format: "This recording exceeds the %.0f GB Orbis limit.", gb)
        case .uploadURLExpired:
            return "The upload URL expired. Try again."
        case .networkError(let err):
            return "Network error: \(err.localizedDescription)"
        case .serverError(let status, let body):
            if let body, !body.isEmpty {
                return "Orbis returned \(status): \(body)"
            }
            return "Orbis returned HTTP \(status)."
        case .decodingError(let err):
            return "Orbis sent an unexpected response: \(err.localizedDescription)"
        case .invalidHost(let h):
            return "Orbis host \"\(h)\" isn't a valid URL."
        }
    }
}

/// Maximum accepted upload size per the Orbis contract (5 GB).
/// Checked client-side before Step A so we don't waste a round-trip.
let orbisMaxUploadBytes: Int64 = 5_368_709_120
