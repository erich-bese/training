import UIKit
import WebKit

/// Receives the messages the injected `Bridge.js` sends and turns them into
/// native behaviour.
///
/// One handler, one `cmd` field. Adding a capability later (Health in stage 2,
/// Live Activities in stage 3) means one more case here and one more shim in
/// `Bridge.js` — the web app is never touched.
final class Bridge: NSObject, WKScriptMessageHandler {

    /// The name the page posts to: `window.webkit.messageHandlers.native`.
    static let handlerName = "native"

    private weak var webView: WKWebView?
    private let store: Store
    private let updater: WebUpdater

    /// Rebuilding a feedback generator per event loses its prepared state, so
    /// they are kept around.
    private let lightTap = UIImpactFeedbackGenerator(style: .light)
    private let mediumTap = UIImpactFeedbackGenerator(style: .medium)
    private let heavyTap = UIImpactFeedbackGenerator(style: .heavy)

    init(store: Store, updater: WebUpdater) {
        self.store = store
        self.updater = updater
        super.init()
    }

    func attach(to webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Injected script

    /// The user script, with the stored data baked in.
    ///
    /// Seeding has to be synchronous — the page's own script runs immediately
    /// after this one and reads `localStorage` on its first line. So the data
    /// is read from disk before the web view is even built and embedded here as
    /// a literal.
    static func userScript(seededWith items: [String: String], version: String) -> WKUserScript {
        guard let url = Bundle.main.url(forResource: "Bridge", withExtension: "js"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            Log.warn("bridge: Bridge.js missing from the bundle")
            return WKUserScript(source: "", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        }

        let seed: String
        if let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8) {
            seed = json
        } else {
            Log.warn("bridge: stored data not encodable, starting the page empty")
            seed = "{}"
        }

        // Version first: the seed is user data and could in principle contain
        // the other placeholder in a note.
        let source = template
            .replacingOccurrences(of: "__VERSION__", with: version)
            .replacingOccurrences(of: "__SEED__", with: seed)
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - Messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }

        switch cmd {
        case "store":
            guard let items = body["items"] as? [String: String] else { return }
            store.write(items)

        case "haptic":
            haptic(ms: body["ms"] as? Int ?? 0)

        case "awake":
            let on = body["on"] as? Bool ?? false
            UIApplication.shared.isIdleTimerDisabled = on

        case "update":
            checkForUpdate()

        /* Health is only ever fetched because the page asked. `ask` is the
           difference between the first time — where iOS puts its own sheet on
           screen — and every refresh afterwards. */
        case "health":
            fetchHealth(ask: body["ask"] as? Bool ?? false)

        case "ready":
            Log.info("bridge: page ready, shell \(body["version"] as? String ?? "?")")
            // Once he has allowed it, the values are simply there when the page
            // opens. Asking again on every start would be the wrong kind of
            // eager.
            if Self.healthAsked { fetchHealth(ask: false) }

        case "log":
            Log.info("page: \(body["text"] as? String ?? "")")

        default:
            Log.warn("bridge: unknown command \(cmd)")
        }
    }

    /// Writes the page's pending changes to disk and reports when they are
    /// actually there.
    ///
    /// Deliberately not the message path: on the way into the background there
    /// is no room for a round trip that iOS might suspend halfway through. The
    /// data comes back as the return value and is written straight away.
    func flushPage(completion: (() -> Void)? = nil) {
        guard let webView else { completion?(); return }
        webView.evaluateJavaScript("window.__training_snapshot ? window.__training_snapshot() : null") { [store] result, _ in
            if let items = result as? [String: String] { store.write(items) }
            store.whenIdle { completion?() }
        }
    }

    // MARK: - Behaviour

    /// The web app's buzz durations, mapped onto something that feels right on
    /// a phone rather than replayed literally.
    private func haptic(ms: Int) {
        switch ms {
        case ..<12: lightTap.impactOccurred()
        case ..<40: mediumTap.impactOccurred()
        default: heavyTap.impactOccurred()
        }
    }

    // MARK: - Health

    /// Whether the Health sheet has been shown once. HealthKit deliberately
    /// never reveals whether reading was granted, so this only records that the
    /// question was asked — not the answer.
    private static var healthAsked: Bool {
        get { UserDefaults.standard.bool(forKey: "healthAsked") }
        set { UserDefaults.standard.set(newValue, forKey: "healthAsked") }
    }

    /// Fetches last night and hands it to the page. Runs on every foreground
    /// once permission has been asked for, so the numbers are current when the
    /// day's form is opened.
    func fetchHealth(ask: Bool) {
        let lesen = { [weak self] in
            Health.shared.summary { dict in self?.pushHealth(dict) }
        }
        guard ask else { lesen(); return }
        Health.shared.authorize { ok in
            Self.healthAsked = true
            if !ok { Log.warn("bridge: health authorisation was not completed") }
            lesen()
        }
    }

    private func pushHealth(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.__training_healthPush && window.__training_healthPush(\(json))")
    }

    private func checkForUpdate() {
        report("Suche nach einer neuen Version …")
        updater.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate(let version):
                self.report("Du bist auf dem aktuellen Stand (Version \(version)). \(self.store.statusText())")
            case .updated(let version):
                self.report("Version \(version) geladen. Starte neu …")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.webView?.reloadFromOrigin()
                }
            case .failed(let reason):
                self.report("Prüfung fehlgeschlagen: \(reason)")
            }
        }
    }

    private func report(_ text: String) {
        let escaped = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView?.evaluateJavaScript("window.__training_updateResult(\(escaped))")
    }
}

/// `WKUserContentController` retains its message handlers, and the handler holds
/// the web view — this breaks that cycle.
final class BridgeProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
