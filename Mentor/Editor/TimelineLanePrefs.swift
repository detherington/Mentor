import Foundation

/// Identifies each of the secondary lanes the timeline can draw below
/// the main track — used as a lookup key by the visibility-override
/// machinery in `EditorViewModel`.
enum TimelineLane: String, CaseIterable, Identifiable {
    case zoom
    case talkingHead
    case soundboard
    case captions
    case keystrokes

    var id: String { rawValue }

    /// Label used in the lane-visibility menu.
    var menuLabel: String {
        switch self {
        case .zoom:        return "Zoom keyframes"
        case .talkingHead: return "Talking-head"
        case .soundboard:  return "Soundboard cues"
        case .captions:    return "Captions"
        case .keystrokes:  return "Keystrokes"
        }
    }
}

/// Per-lane visibility override. `auto` defers to a "has relevant
/// content" heuristic owned by the view model (e.g. zoom lane
/// auto-shows when zoomKeyframes is non-empty); `show` / `hide`
/// force the lane regardless of content.
enum LaneVisibility: String, Codable, Equatable, CaseIterable {
    case auto
    case show
    case hide

    var menuLabel: String {
        switch self {
        case .auto: return "Auto"
        case .show: return "Show"
        case .hide: return "Hide"
        }
    }
}

/// User preferences for which secondary timeline lanes appear beneath
/// the main track. Persisted via Settings so the layout the user
/// prefers follows them across recordings. Defaults to all-auto —
/// feature lanes appear only when their feature has produced data.
struct TimelineLanePrefs: Codable, Equatable, Sendable {
    var zoom: LaneVisibility
    var talkingHead: LaneVisibility
    var soundboard: LaneVisibility
    var captions: LaneVisibility
    var keystrokes: LaneVisibility

    init(
        zoom: LaneVisibility = .auto,
        talkingHead: LaneVisibility = .auto,
        soundboard: LaneVisibility = .auto,
        captions: LaneVisibility = .auto,
        keystrokes: LaneVisibility = .auto
    ) {
        self.zoom = zoom
        self.talkingHead = talkingHead
        self.soundboard = soundboard
        self.captions = captions
        self.keystrokes = keystrokes
    }

    static let `default` = TimelineLanePrefs()

    /// Bulk-apply a single visibility setting to every lane — used by
    /// the "Show all" / "Hide all" / "Reset to Auto" menu items.
    func all(_ v: LaneVisibility) -> TimelineLanePrefs {
        TimelineLanePrefs(
            zoom: v, talkingHead: v, soundboard: v, captions: v, keystrokes: v
        )
    }

    /// Indexed read/write for a single lane.
    subscript(lane: TimelineLane) -> LaneVisibility {
        get {
            switch lane {
            case .zoom:        return zoom
            case .talkingHead: return talkingHead
            case .soundboard:  return soundboard
            case .captions:    return captions
            case .keystrokes:  return keystrokes
            }
        }
        set {
            switch lane {
            case .zoom:        zoom = newValue
            case .talkingHead: talkingHead = newValue
            case .soundboard:  soundboard = newValue
            case .captions:    captions = newValue
            case .keystrokes:  keystrokes = newValue
            }
        }
    }
}
