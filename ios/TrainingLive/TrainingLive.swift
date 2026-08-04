import SwiftUI
import WidgetKit
import ActivityKit

/// Lock screen and Dynamic Island for a running session.
///
/// Nothing in here is animated by the app. The countdown is a `Text` built from
/// a date and the bar a `ProgressView` built from a range — the system ticks
/// both on its own, without waking the app. That is the whole reason a Live
/// Activity can show a running second hand while an app in the background
/// cannot.

private extension Color {
    /* Dieselben Werte wie in der Web-App, damit die Karte auf dem
       Sperrbildschirm nicht wie ein fremdes Programm aussieht. */
    static let knochen = Color(red: 0.949, green: 0.941, blue: 0.925)   // #F2F0EC
    static let amber   = Color(red: 0.914, green: 0.651, blue: 0.235)   // #E9A63C
    static let leise   = Color(red: 0.620, green: 0.639, blue: 0.675)   // #9EA3AC
    static let grund   = Color(red: 0.047, green: 0.078, blue: 0.110)   // #0C141C
}

/// Small caps line, the same eyebrow the app uses above every card.
private struct Braue: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(Color.leise)
            .lineLimit(1)
    }
}

/// The countdown, or the set count while no rest is running. One slot, two
/// meanings — a card with an empty half looks broken.
private struct Zahl: View {
    let state: TrainingAttributes.ContentState
    var groesse: CGFloat = 34

    var body: some View {
        if let bis = state.pauseBis {
            /* `Text(timerInterval:)` belegt die Breite der laengsten Ziffernfolge,
               die je vorkommen kann, und setzt den Text darin linksbuendig.
               Ohne die feste Breite mit rechter Ausrichtung stuende die Zahl
               mitten in der Karte statt an ihrem Rand. */
            Text(timerInterval: Date()...bis, countsDown: true)
                .font(.system(size: groesse, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.trailing)
                .frame(width: groesse * 2.7, alignment: .trailing)
        } else {
            (Text("\(state.erledigt)").foregroundStyle(Color.knochen)
             + Text(" / \(state.gesamt)").foregroundStyle(Color.leise))
                .font(.system(size: groesse, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
    }
}

private struct Balken: View {
    let state: TrainingAttributes.ContentState

    var body: some View {
        if let von = state.pauseVon, let bis = state.pauseBis, bis > von {
            // Runs empty on its own; the app is not woken for a single frame.
            ProgressView(timerInterval: von...bis, countsDown: true)
                .progressViewStyle(.linear)
                .tint(Color.amber)
                .labelsHidden()
        } else {
            ProgressView(value: state.gesamt > 0
                         ? Double(state.erledigt) / Double(state.gesamt) : 0)
                .progressViewStyle(.linear)
                .tint(Color.knochen)
        }
    }
}

struct TrainingLiveView: View {
    let plan: String
    let state: TrainingAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Braue(text: plan)
                Spacer(minLength: 12)
                /* Ohne Pause traegt die grosse Zahl rechts schon die Saetze —
                   sie oben zu wiederholen waere doppelt. */
                Braue(text: state.pauseBis != nil ? "Pause" : "Sätze")
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.uebung)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Color.knochen)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(state.satz)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.leise)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Zahl(state: state)
            }
            Balken(state: state)
        }
        .padding(16)
        .activityBackgroundTint(Color.grund)
        .activitySystemActionForegroundColor(Color.knochen)
    }
}

struct TrainingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrainingAttributes.self) { context in
            TrainingLiveView(plan: context.attributes.plan, state: context.state)

        } dynamicIsland: { context in
            DynamicIsland {
                /* Der Plan steht unten, nicht oben links: die Kamera schneidet
                   dort die ersten Zeichen ab. Nach oben gehoert ohnehin das,
                   was gerade zaehlt — die Uebung. */
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.uebung)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.knochen)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(context.state.satz)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.leise)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Zahl(state: context.state, groesse: 28)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Balken(state: context.state)
                        HStack {
                            Braue(text: context.attributes.plan)
                            Spacer(minLength: 12)
                            Braue(text: "\(context.state.erledigt) / \(context.state.gesamt) Sätze")
                        }
                    }
                }

            } compactLeading: {
                Image(systemName: context.state.pauseBis != nil ? "hourglass" : "figure.strengthtraining.traditional")
                    .foregroundStyle(Color.amber)

            } compactTrailing: {
                if let bis = context.state.pauseBis {
                    Text(timerInterval: Date()...bis, countsDown: true)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.amber)
                        .frame(maxWidth: 44)
                } else {
                    Text("\(context.state.erledigt)/\(context.state.gesamt)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.knochen)
                }

            } minimal: {
                Image(systemName: context.state.pauseBis != nil ? "hourglass" : "figure.strengthtraining.traditional")
                    .foregroundStyle(Color.amber)
            }
        }
    }
}

@main
struct TrainingLiveBundle: WidgetBundle {
    var body: some Widget { TrainingLiveActivity() }
}
