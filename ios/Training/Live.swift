import Foundation
import ActivityKit

/// Runs the Live Activity for a session.
///
/// The page reports what changed; this decides whether that means starting,
/// updating or ending. Deliberately one activity per session, never one per
/// rest — starting and ending an activity every two minutes looks like a
/// flickering notification and costs the system's patience.
@available(iOS 16.2, *)
final class Live {

    static let shared = Live()
    private init() {}

    private var activity: Activity<TrainingAttributes>?

    /// iOS lets the user switch Live Activities off entirely. Then everything
    /// below is a no-op — no error, no fallback, nothing on the lock screen.
    private var erlaubt: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func apply(_ body: [String: Any]) {
        guard erlaubt else { return }
        guard (body["on"] as? Bool) ?? false else { stop(); return }

        let plan = body["plan"] as? String ?? "Training"
        let state = TrainingAttributes.ContentState(
            uebung: body["ex"] as? String ?? "",
            satz: body["satz"] as? String ?? "",
            erledigt: body["done"] as? Int ?? 0,
            gesamt: body["total"] as? Int ?? 0,
            pauseBis: Self.datum(body["restEnds"]),
            pauseVon: Self.datum(body["restFrom"]))

        if let activity, activity.attributes.plan == plan {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        // A different plan means a different session — the old card has to go
        // before the new one appears, otherwise two stack up on the lock screen.
        stop()
        do {
            activity = try Activity.request(
                attributes: TrainingAttributes(plan: plan),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
        } catch {
            Log.warn("live: could not start — \(error.localizedDescription)")
        }
    }

    /// Ends immediately rather than letting the card linger: the session is
    /// over, and a card that stays around is one more thing to swipe away.
    func stop() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// The page sends milliseconds since the epoch, which is what `Date.now()`
    /// hands it. Zero and absent both mean "no rest running".
    private static func datum(_ raw: Any?) -> Date? {
        guard let ms = raw as? Double ?? (raw as? Int).map(Double.init), ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
