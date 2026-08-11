import Foundation
import AVFoundation

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
