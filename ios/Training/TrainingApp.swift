import UIKit

@main
final class TrainingApp: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    private let store = Store.shared
    private let updater = WebUpdater()
    private var shell: WebShell?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Must happen before the web view exists: it decides which copy of the
        // page is on disk and which version the shell reports as running.
        updater.prepare()

        let shell = WebShell(store: store, updater: updater)
        self.shell = shell

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = shell
        window.backgroundColor = .black
        window.makeKeyAndVisible()
        self.window = window

        return true
    }

    /// Last moment at which JavaScript is still guaranteed to run. Everything
    /// the page has not written back yet goes to disk here.
    func applicationWillResignActive(_ application: UIApplication) {
        flushProtected()
    }

    /// The band writes the night into Health somewhere during the morning,
    /// often while the app is already open. Coming back to the front is the
    /// cheapest moment to look again.
    func applicationDidBecomeActive(_ application: UIApplication) {
        shell?.refreshHealth()
        /* Und den Bildschirm wieder festhalten, falls eine Einheit laeuft.
           Ohne diese Zeile blieb er nach dem ersten Wegschalten dunkel: die
           Seite haelt ihre Sperre fuer weiterhin gueltig und fordert sie
           deshalb nie neu an. */
        Bridge.restoreScreenState()
        /* Die Audiositzung ebenso — sie wird beim Wechsel in den Hintergrund
           inaktiv, und ohne Reaktivierung bleibt der Pausenton stumm. */
        shell?.reactivateAudio()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        flushProtected()
        // A rest timer holds this; leaving the app should not leave the screen
        // pinned awake for the next app. The wish itself is remembered in
        // Bridge.awakeGewuenscht and restored on the way back.
        application.isIdleTimerDisabled = false
    }

    func applicationWillTerminate(_ application: UIApplication) {
        flushProtected()
    }

    /// The set he just logged before locking the phone is exactly the one worth
    /// protecting, so the write gets a background assertion rather than racing
    /// the suspend.
    private func flushProtected() {
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = app.beginBackgroundTask(withName: "flush") {
            app.endBackgroundTask(task)
            task = .invalid
        }
        shell?.flush {
            guard task != .invalid else { return }
            app.endBackgroundTask(task)
            task = .invalid
        }
    }
}
