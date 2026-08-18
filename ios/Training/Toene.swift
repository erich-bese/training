import Foundation
import AVFoundation
import UserNotifications
import UIKit

/// The sounds of a session, generated rather than shipped as files.
///
/// They used to come from Web Audio inside the web view. That failed in
/// practice: a rest timer finishing is not a user gesture, the audio context
/// suspends whenever the view is not frontmost, and nothing about it survives
/// the app going to the background. None of those conditions can be met by a
/// timer that has to be audible precisely when the phone is lying on the
/// bench. Natively only the audio session category matters, and that is set
/// to `.playback` — which also means the sounds play with the ring switch on
/// silent, the one place the user actually has the phone during training.
///
/// Two short sine tones per event, written into a buffer and played once.
/// A handful of beeps does not justify shipping audio files, and generating
/// them keeps pitch and length adjustable in one place.
enum Toene {

    /// Kinds of sound the page can ask for.
    ///
    /// - `tick`: a single quiet marker — the seconds counting up on a hold.
    /// - `count`: the last few seconds before something ends, more urgent.
    /// - `ende`: the rest is over, or the hold is done.
    private static let rezepte: [String: [(frequenz: Double, dauer: Double, lautstaerke: Double)]] = [
        "tick":  [(880, 0.07, 0.18)],
        "count": [(1046, 0.10, 0.30)],
        "ende":  [(880, 0.16, 0.34), (1320, 0.22, 0.34)]
    ]

    private static var spieler: AVAudioPlayer?

    /// A buffer of pure silence.
    ///
    /// Not a sound but a lever: an app that is playing audio is not suspended,
    /// and only an app that is not suspended can beep at a moment it chose
    /// earlier. See `Pausenwecker`.
    static func stille(_ sekunden: Double) -> Data? {
        wav([(frequenz: 0, dauer: sekunden, lautstaerke: 0)])
    }

    static func spiel(_ art: String) {
        guard let rezept = rezepte[art] ?? rezepte["ende"] else { return }
        guard let daten = wav(rezept) else { return }
        do {
            /* Die Sitzung kann zwischendurch inaktiv geworden sein — etwa nach
               einem Anruf. Sie hier wieder zu aktivieren ist billig und spart
               den einen Fall, in dem der Ton ohne Grund ausbleibt. */
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: daten)
            p.volume = 1
            p.prepareToPlay()
            p.play()
            /* Festhalten, sonst raeumt ARC den Spieler ab, bevor er klingt. */
            spieler = p
        } catch {
            Log.warn("sound: \(art) failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Generating

    private static let rate = 44100.0

    /// A 16-bit mono WAV of the given tones, played one after another.
    ///
    /// Each tone fades in and out over five milliseconds. Without that the
    /// square edge of a sine starting at full amplitude is audible as a click,
    /// and on a short beep the click is louder than the beep.
    private static func wav(_ toene: [(frequenz: Double, dauer: Double, lautstaerke: Double)]) -> Data? {
        var proben: [Int16] = []
        for ton in toene {
            let anzahl = Int(rate * ton.dauer)
            guard anzahl > 0 else { continue }
            let rampe = max(1, Int(rate * 0.005))
            for i in 0..<anzahl {
                let t = Double(i) / rate
                var a = ton.lautstaerke
                if i < rampe { a *= Double(i) / Double(rampe) }
                if i > anzahl - rampe { a *= Double(anzahl - i) / Double(rampe) }
                let wert = sin(2 * .pi * ton.frequenz * t) * a
                proben.append(Int16(max(-1, min(1, wert)) * 32767))
            }
            // 30 ms of silence between tones, so two beeps read as two.
            proben.append(contentsOf: [Int16](repeating: 0, count: Int(rate * 0.03)))
        }
        guard !proben.isEmpty else { return nil }

        let datenLaenge = proben.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + datenLaenge)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        str("data"); u32(UInt32(datenLaenge))
        proben.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }
}

/// The rest timer's alarm — the one sound that has to arrive while nobody is
/// looking at the screen.
///
/// During a rest the phone lies on the bench or in a pocket. That is exactly
/// when iOS freezes the web view's timers: the page's own per-second tick stops
/// and its beep only happened once the app was brought back to the front, long
/// after the rest was over. No amount of work inside the page fixes this —
/// Web Audio, the audio session category and the visibility rules are all
/// downstream of the app being suspended in the first place.
///
/// So the page stops asking for a sound and hands over a *point in time*
/// instead. Two independent things then have to go wrong for the alarm to be
/// missed:
///
/// 1. **Audio.** A looping buffer of silence keeps the audio session running,
///    and an app that plays audio is not suspended. A timer can therefore fire
///    in the background and play the real tone through the `.playback` session
///    — audible with the ring switch on silent, which is where his phone
///    always is. The silence stops the moment the tone has played; nothing
///    keeps running between sessions.
/// 2. **A local notification** at the same moment. It costs nothing, survives
///    even an app the system did kill, and on a silenced phone it is the
///    vibration in the pocket. Suppressed while the app is frontmost, because
///    there the tone has already been heard.
///
/// Wer Musik hoert, soll sie waehrend der Pause nicht verlieren: die Sitzung
/// bleibt auf `.mixWithOthers`, bis drei Sekunden vor Ende — dann senkt sich
/// die fremde Wiedergabe kurz per `.duckOthers`, damit die 3-2-1-Vorwarnung
/// und der Endton durchdringen, und hebt sich danach wieder.
final class Pausenwecker: NSObject, UNUserNotificationCenterDelegate {

    static let shared = Pausenwecker()

    /// Alle Timer der laufenden Pause: die drei Vorwarntoene und der
    /// Endton. Beim Abbrechen muessen es alle sein, nicht nur der letzte.
    private var timer: [Timer] = []
    private var stille: AVAudioPlayer?
    private var gefragt = false
    /// Haelt fest, ob die fremde Wiedergabe gerade abgesenkt ist — sonst
    /// wuerde jeder der drei Vorwarntoene erneut `duckenAn()` aufrufen.
    private var gedimmt = false

    private static let kennung = "pause"

    /// Called from the page every time a rest starts, is skipped, or the
    /// session ends. A date in the past — or `nil` — cancels.
    func planen(bis ende: Date?) {
        absagen()
        guard let ende else { return }
        let rest = ende.timeIntervalSinceNow
        /* Schon vorbei: dann ist der Ton faellig, nicht der Wecker. Das
           passiert, wenn die Seite nach einem Neuladen nachtraegt. */
        guard rest > 0.4 else { return }

        wachHalten()

        /* Drei kurze Toene als Vorwarnung, dann der eigentliche. Wer Musik
           hoert, braucht den Anlauf: ein einzelner Piep geht im Takt unter.
           Absolute Zeitpunkte statt Restdauern — dieselbe Regel wie beim
           Endton, ein Timer mit `timeInterval:` ueberlebt das Wegschalten
           nicht zuverlaessig. */
        for versatz in [-3.0, -2.0, -1.0, 0.0] {
            let wann = ende.addingTimeInterval(versatz)
            guard wann > Date() else { continue }
            let art = versatz == 0.0 ? "ende" : "count"
            let t = Timer(fire: wann, interval: 0, repeats: false) { [weak self] _ in
                guard let self else { return }
                /* Absenken beim ersten Ton, der tatsaechlich noch faellig
                   ist — nicht zwingend beim -3s-Ton, der Wecker kann auch
                   spaeter mit weniger Vorlauf gestellt werden (Neuladen
                   waehrend der letzten Sekunden der Pause). */
                if !self.gedimmt {
                    self.gedimmt = true
                    self.duckenAn()
                }
                Toene.spiel(art)
                if art == "ende" {
                    self.haptik()
                    /* Der Ton ist raus — ab hier gibt es keinen Grund mehr,
                       die App wach zu halten. Weiterlaufende Stille waere
                       nur Batterie. */
                    self.stilleBeenden()
                    /* Erst nachdem der Ton durch ist, sonst schneidet die
                       Freigabe der Sitzung ihn ab. */
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        self?.duckenAus()
                    }
                }
            }
            /* `.common`, damit er auch waehrend einer Scroll-Geste feuert. */
            RunLoop.main.add(t, forMode: .common)
            timer.append(t)
        }

        melden(zu: ende)
    }

    func absagen() {
        timer.forEach { $0.invalidate() }
        timer.removeAll()
        /* Auch wenn keine Vorwarnung mehr lief: schadet nicht, und faengt
           genau den Fall, in dem waehrend der Vorwarnung uebersprungen wird
           — sonst bleibt die Musik leise. */
        duckenAus()
        stilleBeenden()
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.kennung])
    }

    // MARK: - Ducking

    /// Senkt fremde Wiedergabe ab. Bewusst erst kurz vor dem Ton und nicht
    /// fuer die ganze Pause — sonst laeuft die Musik drei Minuten lang leise.
    private func duckenAn() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    /// Gibt die Lautstaerke wieder frei. Das Absenken haengt an der
    /// Deaktivierung der Sitzung, nicht am blossen Kategoriewechsel —
    /// `setActive(false, options: .notifyOthersOnDeactivation)` ist der
    /// Teil, der Spotify und Apple Music tatsaechlich wieder hochfahren
    /// laesst. Ohne ihn bleibt die Musik leise.
    private func duckenAus() {
        guard gedimmt else {
            return
        }
        gedimmt = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: [.notifyOthersOnDeactivation])
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, options: [.mixWithOthers])
    }

    /// Nur im Vordergrund — im Hintergrund gibt iOS keine Haptik aus. Der
    /// Ton kommt in beiden Faellen, die lokale Mitteilung ebenfalls.
    private func haptik() {
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    // MARK: - Wachbleiben

    private func wachHalten() {
        guard stille == nil else { return }
        /* Eine Sekunde reicht: der Spieler wiederholt sie endlos. Ein laengerer
           Puffer waere nur mehr Speicher fuer dieselbe Wirkung. */
        guard let daten = Toene.stille(1.0) else { return }
        do {
            /* Waehrend der Pause laeuft die Musik des Nutzers unangetastet
               weiter. `.mixWithOthers` heisst: wir sind hier, aber wir
               stoeren nicht — bis `duckenAn()` das kurz vor dem Endton
               aendert. */
            try? AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: daten)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            stille = p
        } catch {
            /* Ohne Stille bleibt der Wecker trotzdem stehen — er feuert dann
               nur, solange die App vorn ist. Die Mitteilung faengt den Rest. */
            Log.warn("pause: silence player failed — \(error.localizedDescription)")
        }
    }

    private func stilleBeenden() {
        stille?.stop()
        stille = nil
    }

    // MARK: - Mitteilung

    private func melden(zu ende: Date) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stellen = {
            let inhalt = UNMutableNotificationContent()
            inhalt.title = "Pause vorbei"
            inhalt.body = "Weiter mit dem nächsten Satz."
            inhalt.sound = .default
            let rest = ende.timeIntervalSinceNow
            guard rest > 0.4 else { return }
            let ausloeser = UNTimeIntervalNotificationTrigger(timeInterval: rest, repeats: false)
            center.add(UNNotificationRequest(identifier: Self.kennung,
                                             content: inhalt, trigger: ausloeser))
        }
        /* Einmal fragen, und zwar erst hier: beim ersten Pausenende, wo der
           Zweck offensichtlich ist. Beim Start der App waere es eine Frage
           ohne erkennbaren Anlass. Ein Nein aendert nichts am Ton. */
        guard gefragt else {
            gefragt = true
            center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                if ok { DispatchQueue.main.async(execute: stellen) }
            }
            return
        }
        stellen()
    }

    /// Nothing to show while the app is frontmost — the tone was audible and a
    /// banner over the running session would only be in the way.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([])
    }
}
