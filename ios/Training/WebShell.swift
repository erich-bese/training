import UIKit
import WebKit
import AVFoundation

/// The whole user interface: one web view, filling the screen.
///
/// Everything the shell adds sits around the page rather than in it — storage,
/// haptics, the idle timer, downloads, audio behaviour. The page is loaded from
/// disk and does not know it is not in a browser.
final class WebShell: UIViewController {

    private let store: Store
    private let updater: WebUpdater
    private let bridge: Bridge

    private var webView: WKWebView!
    private lazy var failureLabel = makeFailureLabel()
    /// Where each running download is being written to. `WKDownload` does not
    /// hand the destination back, so it is kept from the moment it is chosen.
    private var downloadTargets: [ObjectIdentifier: URL] = [:]

    /// Matches the web app's own `--bg`, so there is no white flash before the
    /// first paint and no light strip under the home indicator.
    private static let background = UIColor(red: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255, alpha: 1)

    init(store: Store, updater: WebUpdater) {
        self.store = store
        self.updater = updater
        self.bridge = Bridge(store: store, updater: updater)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersHomeIndicatorAutoHidden: Bool { false }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        overrideUserInterfaceStyle = .dark
        view.backgroundColor = Self.background

        configureAudio()
        buildWebView()
        loadPage()
    }

    /// Writes the page's pending changes through before iOS freezes the app.
    /// The completion runs once they are on disk.
    func flush(completion: (() -> Void)? = nil) {
        bridge.flushPage(completion: completion)
    }

    /// Last night, once more. Called when the app comes back to the front —
    /// the band syncs its night at some point during the morning, and the app
    /// is usually already open by then.
    func refreshHealth() {
        bridge.fetchHealth(ask: false)
    }

    // MARK: - Setup

    private func buildWebView() {
        let content = WKUserContentController()
        // Seeded synchronously: the page reads its data on the first line of
        // its own script, which runs immediately after this one.
        content.addUserScript(Bridge.userScript(seededWith: store.read(), version: Self.shellVersion))
        content.add(BridgeProxy(bridge), name: Bridge.handlerName)

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true
        // The rest timer's beep comes out of a timer, not a tap.
        config.mediaTypesRequiringUserActionForPlayback = []
        config.suppressesIncrementalRendering = false

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = Self.background
        webView.scrollView.backgroundColor = Self.background
        // The page positions itself against the safe area with env() — nothing
        // should be inset on top of that.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }

        bridge.attach(to: webView)
        view.addSubview(webView)

        // Full bleed on all four edges — the background reaches under the
        // status bar and the Dynamic Island, the way every good iOS app looks.
        // The page keeps its content clear of both with env(safe-area-inset-*).
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadPage() {
        let index = updater.indexURL
        guard FileManager.default.fileExists(atPath: index.path) else {
            showFailure("Die App-Dateien fehlen.")
            return
        }
        webView.loadFileURL(index, allowingReadAccessTo: updater.webRoot)
    }

    /// `.playback` lets the rest timer sound with the ring switch on silent,
    /// `.mixWithOthers` keeps whatever he is listening to during training
    /// running instead of ducking it away.
    private func configureAudio() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.warn("audio: session not configured — \(error.localizedDescription)")
        }
    }

    // MARK: - Failure

    private func makeFailureLabel() -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(white: 0.95, alpha: 1)
        label.font = .systemFont(ofSize: 16)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func showFailure(_ text: String) {
        Log.warn("shell: \(text)")
        guard failureLabel.superview == nil else {
            failureLabel.text = text
            return
        }
        failureLabel.text = text
        view.addSubview(failureLabel)
        NSLayoutConstraint.activate([
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            failureLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32)
        ])
    }

    static let shellVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
}

// MARK: - Navigation

extension WebShell: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        // "Backup exportieren" builds a blob and clicks a download link.
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Anything on disk is the app itself. Real links — the attributions —
        // belong in Safari, not inside a shell with no way back.
        if url.isFileURL || url.scheme == "about" {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure("Die App konnte nicht geladen werden.\n\(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Rare, but it would leave a blank screen. The data is on disk, so the
        // page comes back exactly where it was.
        Log.warn("shell: web content process died, reloading")
        loadPage()
    }
}

// MARK: - Downloads

extension WebShell: WKDownloadDelegate {

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let name = suggestedFilename.isEmpty ? "training.json" : suggestedFilename
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        downloadTargets[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let url = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: view.bounds.maxY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        Log.warn("download: \(error.localizedDescription)")
    }
}

// MARK: - Dialogs

/// The page uses `confirm()` for its delete guards. Without this they silently
/// return false and nothing can be deleted.
extension WebShell: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .destructive) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
