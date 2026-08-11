import Foundation
import HealthKit

/// Reads last night out of Apple Health.
///
/// The phone is not the source of these numbers — the Whoop band is. Whoop
/// writes sleep, heart rate variability, resting heart rate and respiratory
/// rate into Health, and Health is the only place a third app is allowed to
/// read them from. Read-only: this app never writes a single sample.
///
/// Every value comes with its own baseline, because none of them means
/// anything on its own. A heart rate variability of 60 ms is good for one
/// person and poor for the next; 60 against an own median of 45 is the
/// statement. The baseline is the median of the last 28 nights — the median
/// rather than the mean, so one night out with friends does not move it.
final class Health {

    static let shared = Health()

    private let store = HKHealthStore()
    private init() {}

    /// The Simulator has HealthKit, an iPad would not.
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var set = Set<HKObjectType>()
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { set.insert(t) }
        for id in [HKQuantityTypeIdentifier.heartRateVariabilitySDNN,
                   .restingHeartRate, .respiratoryRate] {
            if let t = HKObjectType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        return set
    }

    /// Asks once; iOS shows its own sheet and remembers the answer. Health
    /// never tells an app whether reading was allowed — a denied type simply
    /// returns nothing — so there is no point in checking a status afterwards.
    /// The honest signal is whether values come back.
    func authorize(_ done: @escaping (Bool) -> Void) {
        guard isAvailable else { done(false); return }
        store.requestAuthorization(toShare: [], read: readTypes) { ok, error in
            if let error { Log.warn("health: authorisation failed — \(error.localizedDescription)") }
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - Diagnose

    /// Counts the raw samples HealthKit actually holds, per quantity.
    ///
    /// Needed because the aggregating query cannot tell three very different
    /// situations apart — they all come back as "no value": permission not
    /// granted, nothing ever written by any app, or written but outside the
    /// window. A plain sample count with the source names separates them, and
    /// without that separation the next step is guesswork.
    ///
    /// Deliberately a `HKSampleQuery` rather than statistics: it sees exactly
    /// what is stored, with no bucketing in between.
    func diagnose(_ done: @escaping ([String: Any]) -> Void) {
        guard isAvailable else { done([:]); return }
        let felder: [(HKQuantityTypeIdentifier, String)] = [
            (.heartRateVariabilitySDNN, "hrv"),
            (.restingHeartRate, "puls"),
            (.respiratoryRate, "atem")
        ]
        var out: [String: Any] = [:]
        let group = DispatchGroup()
        let lock = NSLock()
        let von = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()

        for (id, key) in felder {
            guard let typ = HKObjectType.quantityType(forIdentifier: id) else { continue }
            group.enter()
            let q = HKSampleQuery(sampleType: typ,
                                  predicate: HKQuery.predicateForSamples(withStart: von, end: Date()),
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, error in
                let liste = (samples as? [HKQuantitySample]) ?? []
                let quellen = Array(Set(liste.map { $0.sourceRevision.source.name })).sorted()
                lock.lock()
                out[key] = [
                    "anzahl": liste.count,
                    "quellen": quellen,
                    "fehler": error?.localizedDescription as Any?
                ].compactMapValues { $0 }
                lock.unlock()
                group.leave()
            }
            store.execute(q)
        }
        group.notify(queue: .main) { done(out) }
    }

    // MARK: - Reading

    /// Last night plus the baselines, as a dictionary ready to hand to the page.
    ///
    /// Nothing here is required. A missing key means Health had nothing —
    /// no permission, no band worn, a night not yet written. The page has to
    /// cope with every single value being absent, and it does.
    func summary(_ done: @escaping ([String: Any]) -> Void) {
        guard isAvailable else { done(["ok": false, "grund": "nicht verfügbar"]); return }

        var out: [String: Any] = ["ok": true, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        let group = DispatchGroup()
        let lock = NSLock()
        func put(_ key: String, _ value: Any?) {
            guard let value else { return }
            lock.lock(); out[key] = value; lock.unlock()
        }
        /// One row per night for the page's own history. A single night says
        /// almost nothing — night-to-night HRV moves as much as the whole
        /// year's spread — so the page averages over a window, and for that
        /// it needs the nights, not just the last one.
        var proNacht: [String: [String: Any]] = [:]
        func nacht(_ tag: String, _ key: String, _ value: Any?) {
            guard let value else { return }
            lock.lock()
            proNacht[tag, default: ["nacht": tag]][key] = value
            lock.unlock()
        }

        group.enter()
        sleepMinutes(nights: 28) { last, base, quelle, nachtKey, verlauf in
            put("schlaf", last); put("schlafBasis", base); put("quelle", quelle)
            /* Welche Nacht gemeint ist, nicht wann gelesen wurde. Ohne diese
               Angabe steht auf der Startseite eine Zahl ohne Zeitpunkt — und
               man weiss nicht, ob sie von heute Nacht oder von vorgestern ist,
               weil das Band manchmal Tage spaeter synchronisiert. */
            put("nacht", nachtKey)
            for (tag, minuten) in verlauf {
                nacht(tag, "schlaf", minuten)
                nacht(tag, "schlafBasis", base)
            }
            group.leave()
        }

        let felder: [(HKQuantityTypeIdentifier, String, HKUnit, HKStatisticsOptions)] = [
            (.heartRateVariabilitySDNN, "hrv", .secondUnit(with: .milli), .discreteAverage),
            (.restingHeartRate, "puls", HKUnit.count().unitDivided(by: .minute()), .discreteAverage),
            (.respiratoryRate, "atem", HKUnit.count().unitDivided(by: .minute()), .discreteAverage)
        ]
        for (id, key, unit, option) in felder {
            group.enter()
            nightly(id, unit: unit, option: option, nights: 28) { last, base, verlauf in
                put(key, last); put(key + "Basis", base)
                for (tag, wert) in verlauf {
                    nacht(tag, key, wert)
                    nacht(tag, key + "Basis", base)
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            /* Newest first, and only what the window needs. Sending 28 nights
               would put the whole month into local storage on every read for
               a three-night median. */
            out["verlauf"] = proNacht.keys.sorted(by: >).prefix(14).compactMap { proNacht[$0] }
            done(out)
        }
    }

    /// Minutes actually asleep last night, and the median of the 28 nights
    /// before it.
    ///
    /// A night is cut at midday, not at midnight: whatever was slept before
    /// noon belongs to the night before. Only the stages that are sleep count —
    /// `inBed` would count lying awake, and Whoop writes both.
    ///
    /// Returns, besides last night and the baseline, one entry per night for
    /// the page's window — keyed `yyyy-MM-dd`, the evening the night began.
    private func sleepMinutes(nights: Int,
                              _ done: @escaping (Int?, Int?, String?, String?, [(String, Int)]) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            done(nil, nil, nil, nil, []); return
        }
        let cal = Calendar.current
        let mittag = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        let von = cal.date(byAdding: .day, value: -(nights + 1), to: mittag) ?? mittag

        let query = HKSampleQuery(sampleType: type,
                                  predicate: HKQuery.predicateForSamples(withStart: von, end: Date()),
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil) { _, samples, _ in
            let schlafend: Set<Int> = [
                HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
                HKCategoryValueSleepAnalysis.asleepREM.rawValue
            ]
            /* Nicht einfach aufaddieren. Zwei Fallen stecken darin, und beide
               machen die Nacht zu lang:

               1. Mehrere Quellen. Schreiben Whoop und die Uhr dieselbe Nacht,
                  zaehlt jede Minute doppelt. Deshalb je Quelle getrennt
                  rechnen und die nehmen, die am meisten von der Nacht kennt.
               2. Ueberlappende Abschnitte innerhalb einer Quelle. Manche
                  Geraete schreiben zusaetzlich zu "Kernschlaf/Tief/REM" noch
                  einen umspannenden "Schlaf"-Abschnitt — die Summe waere dann
                  glatt das Doppelte. Deshalb die Abschnitte vereinigen, nicht
                  addieren. */
            var proQuelle: [String: [Date: [(Date, Date)]]] = [:]
            for s in (samples as? [HKCategorySample]) ?? [] {
                guard schlafend.contains(s.value) else { continue }
                // Ends before midday -> counts towards that day's night.
                let tag = cal.startOfDay(for: cal.date(byAdding: .hour, value: -12, to: s.endDate) ?? s.endDate)
                proQuelle[s.sourceRevision.source.name, default: [:]][tag, default: []]
                    .append((s.startDate, s.endDate))
            }
            var proNacht: [Date: Double] = [:]
            var quelleJeNacht: [Date: String] = [:]
            for (name, naechte) in proQuelle {
                for (tag, abschnitte) in naechte {
                    let minuten = Health.vereinigteMinuten(abschnitte)
                    if minuten > (proNacht[tag] ?? 0) {
                        proNacht[tag] = minuten
                        quelleJeNacht[tag] = name
                    }
                }
            }
            let sortiert = proNacht.keys.sorted()
            let quelle = sortiert.last.flatMap { quelleJeNacht[$0] }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let verlauf = sortiert.map { (f.string(from: $0), Int((proNacht[$0] ?? 0).rounded())) }
            guard let letzte = sortiert.last else { done(nil, nil, quelle, nil, verlauf); return }
            let vorherige = sortiert.dropLast().compactMap { proNacht[$0] }
            done(Int(proNacht[letzte]?.rounded() ?? 0),
                 Health.median(vorherige).map { Int($0.rounded()) },
                 quelle, f.string(from: letzte), verlauf)
        }
        store.execute(query)
    }

    /// One value per night for a quantity, plus the median of the nights before.
    ///
    /// Whoop writes these once per night, at the end of sleep. Should there be
    /// several samples in a night, they are averaged — `.discreteAverage` over
    /// a daily interval does exactly that.
    private func nightly(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         option: HKStatisticsOptions, nights: Int,
                         _ done: @escaping (Double?, Double?, [(String, Double)]) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { done(nil, nil, []); return }
        let cal = Calendar.current
        let anker = cal.startOfDay(for: Date())
        let von = cal.date(byAdding: .day, value: -(nights + 1), to: anker) ?? anker

        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: HKQuery.predicateForSamples(withStart: von, end: Date()),
            options: option,
            anchorDate: anker,
            intervalComponents: DateComponents(day: 1))

        query.initialResultsHandler = { _, ergebnis, _ in
            var werte: [(Date, Double)] = []
            ergebnis?.enumerateStatistics(from: von, to: Date()) { stat, _ in
                if let q = stat.averageQuantity() ?? stat.mostRecentQuantity() {
                    werte.append((stat.startDate, q.doubleValue(for: unit)))
                }
            }
            werte.sort { $0.0 < $1.0 }
            /* Der Tagesschluessel ist der Abend, an dem die Nacht begann —
               dieselbe Verschiebung wie beim Schlaf, sonst passen die Werte
               im Verlauf nicht zur selben Nacht. Health verankert diese
               Groessen am Morgen, also einen Tag zurueck. */
            let cal2 = Calendar.current
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let verlauf = werte.map { paar -> (String, Double) in
                let abend = cal2.date(byAdding: .day, value: -1, to: paar.0) ?? paar.0
                return (f.string(from: abend), (paar.1 * 10).rounded() / 10)
            }
            guard let letzter = werte.last else { done(nil, nil, verlauf); return }
            let vorher = werte.dropLast().map { $0.1 }
            done((letzter.1 * 10).rounded() / 10,
                 Health.median(vorher).map { ($0 * 10).rounded() / 10 }, verlauf)
        }
        store.execute(query)
    }

    /// Wie viele Naechte mindestens vorliegen muessen, damit die Grundlinie
    /// etwas taugt. Der Median aus zwei Naechten ist keine Grundlinie, sondern
    /// eine der beiden Zahlen — und eine Empfehlung, die darauf fusst, waere
    /// geraten. Gerade nach dem ersten Verbinden von Whoop steht genau eine
    /// Nacht in Health; ohne diese Schranke haette die App daraus sofort
    /// "unter deinem Schnitt" gefolgert.
    private static let baselineMin = 7

    /// Total minutes covered by a set of intervals, counting overlap once.
    ///
    /// Sort by start, then walk: an interval that begins before the current
    /// block ends only extends it. Without this a night written as both
    /// "asleep" and its individual stages comes out twice as long.
    static func vereinigteMinuten(_ abschnitte: [(Date, Date)]) -> Double {
        let sortiert = abschnitte.sorted { $0.0 < $1.0 }
        var summe: TimeInterval = 0
        var start: Date?
        var ende: Date?
        for (von, bis) in sortiert {
            guard bis > von else { continue }
            if let e = ende, let s = start {
                if von <= e {
                    if bis > e { ende = bis }
                } else {
                    summe += e.timeIntervalSince(s)
                    start = von; ende = bis
                }
            } else {
                start = von; ende = bis
            }
        }
        if let s = start, let e = ende { summe += e.timeIntervalSince(s) }
        return summe / 60
    }

    /// Median rather than mean: one outlier night must not shift the baseline
    /// that every deviation is measured against.
    private static func median(_ werte: [Double]) -> Double? {
        guard werte.count >= baselineMin else { return nil }
        let s = werte.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
