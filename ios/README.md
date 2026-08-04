# Training — native iOS-Hülle

Native App um die bestehende Web-App herum. **Kein Neubau.** Die Web-App unter
`../index.html` bleibt unverändert und weiß nicht, dass sie in einer App läuft.

Zweck: die drei Dinge, die im Browser grundsätzlich nicht gehen —
iCloud-Sicherung ohne manuellen Export, Apple Health als Datenquelle, Live
Activities auf dem Sperrbildschirm.

## Stand

| Stufe | Inhalt | Stand |
|---|---|---|
| 1 | Projekt, WKWebView-Hülle, JS↔Swift-Brücke, iCloud-Sicherung | steht |
| 2 | Apple Health lesen | steht |
| 3 | Live Activity für Pause und Übung | offen |

## Wie die Daten laufen

Die entscheidende Entscheidung: **die native Seite besitzt die Daten, nicht die
Seite.** In einer `WKWebView` ist `localStorage` unter `file://` unzuverlässig,
und WebKit darf Website-Daten jederzeit wegräumen. Deshalb:

1. Beim Start liest `Store` die Daten von der Platte — noch bevor die WebView
   existiert.
2. `Bridge.swift` backt sie in `Bridge.js` ein und injiziert das Skript
   **at document start**, also vor dem eigenen Skript der Seite.
3. `Bridge.js` ersetzt `window.localStorage` durch eine eigene Umsetzung, die
   mit diesen Daten vorbelegt ist und jede Änderung nach nativ zurückmeldet
   (gebündelt über 250 ms, plus Zwangsschreiben bei jedem Weg aus dem
   Vordergrund).
4. `Store` schreibt nach `Application Support/TrainingData/state.json` —
   atomar, mit `state.previous.json` und bis zu 30 Tagesständen daneben.

`Application Support` ist Teil des iCloud-Gerätebackups. Das ist die
iCloud-Sicherung: kein Export, kein Knopf, keine Datei.

Die Web-App merkt von all dem nichts. Im Browser läuft sie unverändert weiter.

## Was die Hülle sonst noch übernimmt

| In der Web-App | In der Hülle |
|---|---|
| `navigator.vibrate` (unter iOS wirkungslos) | Taptic Engine, nach Dauer abgestuft |
| `navigator.wakeLock` | nativer Idle-Timer, wird beim Verlassen freigegeben |
| Ton aus dem Pausentimer | `AVAudioSession .playback` — klingt auch bei Stummschalter, unterbricht laufende Musik nicht |
| `confirm()` in den Löschabfragen | native Dialoge (sonst antworten sie stumm mit „nein") |
| „Backup exportieren" (Blob-Download) | `WKDownloadDelegate` plus Teilen-Ansicht |
| „Nach Updates suchen" (Service Worker) | holt `index.html` direkt von GitHub Pages |

## Apple Health

Nur lesend, vier Werte: Schlafdauer, Herzratenvariabilität, Ruhepuls,
Atemfrequenz. Die Zahlen kommen nicht vom Telefon, sondern vom Whoop-Band —
Health ist nur der Ort, an dem eine fremde App sie abholen darf.

Jeder Wert kommt **mit seiner eigenen Grundlinie**: dem Median der letzten 28
Nächte. Ohne die sagt keiner der Werte etwas — 60 ms HRV sind für den einen
viel und für den nächsten wenig. Median statt Mittel, damit eine einzelne
Nacht die Grundlinie nicht verschiebt.

Die Nacht wird **am Mittag geschnitten**, nicht um Mitternacht: Schlaf vor
zwölf Uhr gehört zur Nacht davor. Gezählt werden nur die Schlafstufen,
`inBed` würde waches Liegen mitzählen.

Ablauf: Die Seite fragt (`__training_healthRequest()`), iOS zeigt seine
Nachfrage, die Hülle liest und schiebt das Ergebnis über
`__training_healthPush()` zurück. Danach liest sie bei jedem Wechsel in den
Vordergrund erneut — das Band trägt seine Nacht im Laufe des Vormittags ein.

In der Web-App steht das Ergebnis über der Tagesform und belegt Schlaf,
Energie und Erschöpfung vor. Muskeln und Motivation nicht: die weiß das Band
nicht. Alles überschreibbar, und im Browser fehlt der Block ersatzlos.

**HealthKit verrät nie, ob Lesen erlaubt wurde** — eine gesperrte Größe
liefert einfach nichts. Deshalb wird nur gemerkt, dass gefragt wurde, nie die
Antwort. Das ehrliche Signal ist, ob Werte zurückkommen.

## Updates der Web-App

Die App bringt eine Kopie der Web-App mit, damit sie offline und beim ersten
Start funktioniert. Diese Kopie wird beim Start nach
`Application Support/web/` ausgepackt — und von dort ersetzt die Hülle
`index.html` durch die Fassung, die live auf GitHub Pages steht.

**Der Arbeitsablauf der Web-App bleibt damit derselbe:** `git push`, und die
native App zieht beim nächsten „Nach Updates suchen" nach. Kein Neubau, kein
Kabel, kein Xcode. Die mitgelieferte Kopie ist nur der Boden, auf den sie
zurückfallen kann; ist sie neuer als das Heruntergeladene, gewinnt sie.

Verglichen wird über `APP_VERSION` aus `index.html`, numerisch je Stelle —
4.10 steht damit über 4.9.

## Bauen

```bash
xcodebuild -project ios/Training.xcodeproj -scheme Training \
  -destination 'generic/platform=iOS' -configuration Debug build
```

`sync-web.sh` läuft als erste Bauphase und kopiert die Web-App nach
`Training/web/`. Dieser Ordner wird erzeugt und ist nicht im Repo.

## Aufs iPhone

**Der gewählte Weg ist TestFlight** — kein Kabel, kein Entwicklermodus,
90 Tage je Build. Braucht die aktive Mitgliedschaft im Entwicklerprogramm.

```bash
ASC_KEY_ID=… ASC_ISSUER_ID=… ./upload-testflight.sh
```

Einmalig davor: App-Eintrag in App Store Connect mit der Bundle-ID
`de.besemedia.training`, dazu ein API-Schlüssel unter *Users and Access →
Integrations*. Die `.p8`-Datei gibt es nur ein einziges Mal zum Herunterladen.

`install-device.sh` gibt es als zweiten Weg über Kabel. Der verlangt den
Entwicklermodus auf dem iPhone und ist deshalb nicht der Standardweg. Wird nur
gebraucht, wenn etwas dringend aufs Gerät muss, bevor TestFlight steht.

**Nicht in den App Store.** Eine Hülle um eine Website fällt unter Richtlinie
4.2 und würde abgelehnt. Für den persönlichen Trainingsplan ist das ohne
Belang; für eine öffentliche Bese-Media-App wäre diese Bauweise der falsche
Ausgangspunkt.

## Dateien

| Datei | Zweck |
|---|---|
| `Training/TrainingApp.swift` | `@main`, Fenster, Schreiben beim Verlassen |
| `Training/WebShell.swift` | die WebView, Navigation, Downloads, Dialoge, Audio |
| `Training/Bridge.swift` | nimmt die Nachrichten der Seite entgegen, injiziert das Skript |
| `Training/Resources/Bridge.js` | alles, was in der Seite passiert |
| `Training/Store.swift` | Datenhaltung, Schnappschüsse |
| `Training/Health.swift` | letzte Nacht aus Apple Health, mit Grundlinien |
| `Training/WebUpdater.swift` | Kopie der Web-App auspacken und aktuell halten |
| `Training/Log.swift` | Diagnose, in der Konsole des Macs lesbar |
| `sync-web.sh` | kopiert die Web-App ins Ziel |

## Randbedingungen

- Bundle-ID `de.besemedia.training`, nur iPhone, nur Hochformat, iOS 17+
- HealthKit-Berechtigung in `Training/Training.entitlements`; der TestFlight-Build
  braucht die Fähigkeit **HealthKit** im Profil der App-ID
- `DEVELOPMENT_TEAM` ist leer, bis das Entwicklerprogramm steht
- Keine Abhängigkeiten, kein Paketmanager — passend zur Web-App
