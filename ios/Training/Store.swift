import Foundation

/// Owns the training data.
///
/// This is the whole point of the native shell. In a `WKWebView` the web view's
/// own `localStorage` is not a place you can trust: for `file://` origins it is
/// unreliable to begin with, and WebKit is free to evict website data when the
/// device runs low on space. So the page does not keep the data — this does.
///
/// The file lives under `Application Support`, which is included in the iCloud
/// device backup (unlike `Caches`). That is the "iCloud-Sicherung" of stage 1:
/// the data rides along in the normal device backup, no manual export needed.
///
/// The payload is the page's entire key/value store, so the web app's data model
/// stays its own business. The shell never parses or migrates it.
final class Store {

    static let shared = Store()

    private let fm = FileManager.default
    /// All disk work is serialised here; `write` is called from the main thread
    /// on every change and must not block it.
    private let queue = DispatchQueue(label: "de.besemedia.training.store", qos: .utility)

    /// How many dated snapshots to keep. Roughly a month of training at one
    /// session a day, and a few hundred kilobytes in total.
    private let snapshotLimit = 30

    private lazy var root: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrainingData", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private var previousURL: URL { root.appendingPathComponent("state.previous.json") }

    private lazy var snapshotDir: URL = {
        let dir = root.appendingPathComponent("snapshots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Reading

    /// The stored key/value pairs, empty on a fresh install.
    ///
    /// Called once before the web view exists, so it is deliberately synchronous.
    func read() -> [String: String] {
        for url in [stateURL, previousURL] {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let items = try? JSONDecoder().decode([String: String].self, from: data) {
                return items
            }
            Log.warn("store: \(url.lastPathComponent) unreadable, trying fallback")
        }
        return [:]
    }

    // MARK: - Writing

    /// Persists the page's key/value store.
    ///
    /// Writes are atomic and the previous file is kept, so a crash halfway
    /// through can never leave a truncated `state.json` as the only copy.
    func write(_ items: [String: String]) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(items) else {
                Log.warn("store: payload not encodable, write skipped")
                return
            }
            // Unchanged content is the common case — the page flushes on a timer.
            let old = try? Data(contentsOf: stateURL)
            if let old, old == data { return }

            // Ein Riegel gegen genau den Fall, der einmal passiert ist: die
            // Seite meldet einen leeren Speicher, waehrend hier ein voller
            // liegt. Leer ist nie eine gueltige Meldung — selbst ein
            // Zuruecksetzen in der App hinterlaesst den Schluessel mit einem
            // leeren Datenmodell darin, nicht ein leeres Woerterbuch. Was
            // dahintersteckt, gehoert behoben; ueberschrieben werden darf
            // deswegen trotzdem nichts.
            if items.isEmpty, let old, !old.isEmpty, old.count > 2 {
                Log.warn("store: leere Meldung verworfen, \(old.count) Byte auf der Platte bleiben stehen")
                return
            }

            rotate()
            do {
                try data.write(to: stateURL, options: .atomic)
            } catch {
                Log.warn("store: write failed — \(error.localizedDescription)")
            }
        }
    }

    /// Runs the block once every write handed over so far has reached the disk.
    /// The queue is serial, so being enqueued behind them is enough.
    func whenIdle(_ block: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: block) }
    }

    /// Moves the current state aside before it is overwritten: always to
    /// `state.previous.json`, and once per calendar day into `snapshots/`.
    private func rotate() {
        guard let current = try? Data(contentsOf: stateURL) else { return }
        try? current.write(to: previousURL, options: .atomic)

        let name = "state-\(Self.dayKey(Date())).json"
        let snapshot = snapshotDir.appendingPathComponent(name)
        if !fm.fileExists(atPath: snapshot.path) {
            try? current.write(to: snapshot, options: .atomic)
            pruneSnapshots()
        }
    }

    private func pruneSnapshots() {
        guard let all = try? fm.contentsOfDirectory(atPath: snapshotDir.path) else { return }
        let stale = all.filter { $0.hasPrefix("state-") }.sorted().dropLast(snapshotLimit)
        for name in stale {
            try? fm.removeItem(at: snapshotDir.appendingPathComponent(name))
        }
    }

    // MARK: - Status

    /// Human-readable state of the store, shown in the app's update line so the
    /// bridge can be verified from the phone without a debugger attached.
    func statusText() -> String {
        let attrs = try? fm.attributesOfItem(atPath: stateURL.path)
        guard let size = attrs?[.size] as? Int, let date = attrs?[.modificationDate] as? Date else {
            return "Noch nichts gesichert."
        }
        let kb = max(1, size / 1024)
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMM, HH:mm"
        let count = (try? fm.contentsOfDirectory(atPath: snapshotDir.path))?
            .filter { $0.hasPrefix("state-") }.count ?? 0
        let reserve = count == 1 ? "ein Stand" : "\(count) Stände"
        return "Gesichert: \(kb) KB, \(f.string(from: date)), \(reserve) in Reserve."
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
