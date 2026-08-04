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

        group.enter()
        sleepMinutes(nights: 28) { last, base, quelle in
            put("schlaf", last); put("schlafBasis", base); put("quelle", quelle)
            group.leave()
        }

        let felder: [(HKQuantityTypeIdentifier, String, HKUnit, HKStatisticsOptions)] = [
            (.heartRateVariabilitySDNN, "hrv", .secondUnit(with: .milli), .discreteAverage),
            (.restingHeartRate, "puls", HKUnit.count().unitDivided(by: .minute()), .discreteAverage),
            (.respiratoryRate, "atem", HKUnit.count().unitDivided(by: .minute()), .discreteAverage)
        ]
        for (id, key, unit, option) in felder {
            group.enter()
            nightly(id, unit: unit, option: option, nights: 28) { last, base in
                put(key, last); put(key + "Basis", base)
                group.leave()
            }
        }

        group.notify(queue: .main) { done(out) }
    }

    /// Minutes actually asleep last night, and the median of the 28 nights
    /// before it.
    ///
    /// A night is cut at midday, not at midnight: whatever was slept before
    /// noon belongs to the night before. Only the stages that are sleep count —
    /// `inBed` would count lying awake, and Whoop writes both.
    private func sleepMinutes(nights: Int, _ done: @escaping (Int?, Int?, String?) -> Void) {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            done(nil, nil, nil); return
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
            var proNacht: [Date: Double] = [:]
            var quelle: String?
            for s in (samples as? [HKCategorySample]) ?? [] {
                guard schlafend.contains(s.value) else { continue }
                // Ends before midday -> counts towards that day's night.
                let tag = cal.startOfDay(for: cal.date(byAdding: .hour, value: -12, to: s.endDate) ?? s.endDate)
                proNacht[tag, default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60
                if quelle == nil { quelle = s.sourceRevision.source.name }
            }
            let sortiert = proNacht.keys.sorted()
            guard let letzte = sortiert.last else { done(nil, nil, quelle); return }
            let vorherige = sortiert.dropLast().compactMap { proNacht[$0] }
            done(Int(proNacht[letzte]?.rounded() ?? 0),
                 Health.median(vorherige).map { Int($0.rounded()) },
                 quelle)
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
                         _ done: @escaping (Double?, Double?) -> Void) {
        guard let type = HKObjectType.quantityType(forIdentifier: id) else { done(nil, nil); return }
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
            guard let letzter = werte.last else { done(nil, nil); return }
            let vorher = werte.dropLast().map { $0.1 }
            done((letzter.1 * 10).rounded() / 10,
                 Health.median(vorher).map { ($0 * 10).rounded() / 10 })
        }
        store.execute(query)
    }

    /// Median rather than mean: one outlier night must not shift the baseline
    /// that every deviation is measured against.
    private static func median(_ werte: [Double]) -> Double? {
        guard !werte.isEmpty else { return nil }
        let s = werte.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }
}
