import Foundation
import ActivityKit

/// What the lock screen and the Dynamic Island show during a session.
///
/// Shared between the app and the widget extension — the same file is compiled
/// into both. That is the only way the two agree on the shape of the payload,
/// and one of the few places where duplicating a type would go wrong silently.
struct TrainingAttributes: ActivityAttributes {

    /// Fixed for the life of the activity.
    let plan: String

    struct ContentState: Codable, Hashable {
        /// The exercise the next open set belongs to.
        var uebung: String
        /// "2 / 4" — which set of that exercise is next.
        var satz: String
        /// Sets done and planned for the whole session.
        var erledigt: Int
        var gesamt: Int
        /// When the rest ends. `nil` means no rest is running — the difference
        /// between counting down and standing still.
        ///
        /// A date, not a number of seconds: the system ticks the countdown
        /// itself from this, without the app being woken once. An activity that
        /// had to be updated every second would be throttled away within
        /// minutes.
        var pauseBis: Date?
        /// Start of the rest, so the ring can show how much is left of it.
        var pauseVon: Date?
    }
}
