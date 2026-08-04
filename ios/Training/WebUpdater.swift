import Foundation

/// Keeps the embedded copy of the web app current.
///
/// The app ships with a copy of the web app in its bundle, which is what makes
/// it work offline and on first launch. That copy is unpacked into
/// `Application Support/web` once, and from then on the shell can replace
/// `index.html` there with whatever is live on GitHub Pages.
///
/// This keeps the existing way of working intact: the web app is still deployed
/// with a `git push`, and the native app follows — no rebuild, no cable, no
/// Xcode. The bundled copy stays as the floor it can always fall back to.
final class WebUpdater {

    enum Result {
        case upToDate(String)
        case updated(String)
        case failed(String)
    }

    private let remote = URL(string: "https://erich-bese.github.io/training/index.html")!
    private let fm = FileManager.default

    /// The version that was on disk when the app started, i.e. the one the
    /// running page was built from. A background update writes a newer file
    /// without touching the page, so this is what "running" has to be measured
    /// against, not the file.
    private(set) var runningVersion = "?"

    /// Where the page is served from. Writable, unlike the bundle.
    private(set) lazy var webRoot: URL = {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("web", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var indexURL: URL { webRoot.appendingPathComponent("index.html") }

    // MARK: - Preparing the copy on disk

    /// Unpacks the bundled web app on first launch, and again whenever the
    /// bundled copy is newer than what is on disk — that is the case after a
    /// fresh install from Xcode, and it must win over a stale download.
    ///
    /// Runs before the web view is created, so it is synchronous by design.
    func prepare() {
        // A folder reference lands as a plain directory in the bundle; the
        // resource lookup finds it, but the direct path is the honest fallback.
        let bundled = Bundle.main.url(forResource: "web", withExtension: nil)
            ?? Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
        guard let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("index.html").path) else {
            Log.warn("updater: bundled web app missing — check the build phase")
            return
        }

        let onDisk = Self.version(of: indexURL)
        let inBundle = Self.version(of: bundled.appendingPathComponent("index.html"))

        if onDisk == nil || Self.isNewer(inBundle, than: onDisk) {
            copyContents(of: bundled, to: webRoot)
            Log.info("updater: unpacked bundled web app \(inBundle ?? "?")")
        }

        runningVersion = Self.version(of: indexURL) ?? "?"
        Log.info("updater: serving version \(runningVersion)")
    }

    private func copyContents(of source: URL, to target: URL) {
        guard let names = try? fm.contentsOfDirectory(atPath: source.path) else { return }
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            try? fm.removeItem(at: to)
            do { try fm.copyItem(at: from, to: to) }
            catch { Log.warn("updater: could not unpack \(name) — \(error.localizedDescription)") }
        }
    }

    // MARK: - Fetching

    /// Fetches the live `index.html` and installs it if it is newer.
    ///
    /// The completion runs on the main queue.
    func check(completion: @escaping (Result) -> Void) {
        func done(_ result: Result) { DispatchQueue.main.async { completion(result) } }

        var request = URLRequest(url: remote)
        // GitHub Pages sits behind a CDN; without this a stale copy comes back
        // for minutes after a push.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error { return done(.failed(Self.reason(for: error))) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                return done(.failed("Server meldet \(code)."))
            }
            guard let data, let text = String(data: data, encoding: .utf8) else {
                return done(.failed("Antwort nicht lesbar."))
            }
            // A captive portal or an error page would otherwise happily
            // overwrite a working app.
            guard let fetched = Self.version(in: text), text.contains("</html>") else {
                return done(.failed("Das war nicht die App."))
            }

            let current = Self.version(of: self.indexURL)
            guard Self.isNewer(fetched, than: current) || Self.isNewer(fetched, than: self.runningVersion) else {
                return done(.upToDate(self.runningVersion))
            }

            do {
                try data.write(to: self.indexURL, options: .atomic)
                Log.info("updater: installed version \(fetched)")
                done(.updated(fetched))
            } catch {
                done(.failed("Konnte nicht gespeichert werden."))
            }
        }.resume()
    }

    // MARK: - Versions

    /// Reads `APP_VERSION` straight out of the page. It is the single marker
    /// the web app maintains for exactly this purpose.
    private static func version(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return version(in: text)
    }

    private static func version(in text: String) -> String? {
        guard let range = text.range(of: #"APP_VERSION\s*=\s*"([0-9]+(\.[0-9]+)*)""#,
                                     options: .regularExpression) else { return nil }
        return text[range].split(separator: "\"").dropFirst().first.map(String.init)
    }

    /// Numeric comparison, so 4.10 sorts above 4.9.
    private static func isNewer(_ candidate: String?, than current: String?) -> Bool {
        guard let candidate else { return false }
        guard let current, current != "?" else { return true }
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func reason(for error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return "Keine Verbindung."
        case NSURLErrorTimedOut: return "Zeitüberschreitung."
        default: return "Netzwerkfehler."
        }
    }
}
