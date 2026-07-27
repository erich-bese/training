# Training

Persönlicher Trainingsplan-Tracker als installierbare PWA. Statisches HTML, CSS und
JavaScript – kein Build-Schritt, keine Abhängigkeiten, kein Server, kein Konto,
kein Tracking.

## Was die App macht

- **Heute** – zeigt die für den Wochentag geplante Einheit (Push, Pull, Beine im
  A/B-Wechsel), startet das Training, zählt Sätze und Wiederholungen mit und blendet
  nach jedem Satz einen Pausentimer ein.
- **Automatische Gewichtssteuerung** – nach jeder Einheit wird ausgewertet: alle Sätze
  im Zielbereich bedeutet Gewicht rauf, dreimal in Folge unter dem Ziel bedeutet
  10 % runter. Die Empfehlung erscheint als „Nächstes Mal“-Karte.
- **Verlauf** – Monatskalender mit farbig markierten Trainingstagen plus die letzten
  Einheiten im Detail, filterbar nach Push, Pull und Beine.
- **Fortschritt** – Hauptziele mit Fortschrittsbalken, Trainings pro Woche,
  Gesamtwiederholungen, bewegtes Gewicht und persönliche Rekorde.
- **Mehr** – Körpergewicht, Länge der Satzpause, Backup und Zurücksetzen.

## Installation auf dem iPhone

1. Die Seite in **Safari** öffnen (nicht in Chrome – nur Safari darf auf iOS zum
   Home-Bildschirm hinzufügen).
2. Auf **Teilen** tippen (Quadrat mit Pfeil nach oben).
3. **Zum Home-Bildschirm** wählen und bestätigen.

Die App startet danach im Vollbild ohne Safari-Leiste. Einmal mit Netz öffnen, damit
der Service Worker die App-Shell ablegt – ab dann startet sie auch offline.

Auf Android führt Chrome über **Menü › App installieren** zum selben Ergebnis.

## Wo die Daten liegen

Alle Trainingsdaten liegen im `localStorage` des jeweiligen Geräts. Es gibt keine
Synchronisation zwischen Geräten und keine Kopie auf einem Server. Das bedeutet auch:
Wer den Browser-Speicher der Seite löscht oder die App vom Home-Bildschirm entfernt,
löscht seine Trainingsdaten mit.

Deshalb regelmäßig ein Backup ziehen.

## Backup per JSON

**Exportieren:** Tab **Mehr › Backup exportieren**. Die App legt eine Datei
`training-JJJJ-MM-TT.json` ab – auf dem iPhone landet sie über das Teilen-Menü in
Dateien oder iCloud Drive. Die Datei enthält den kompletten Stand: alle Einheiten,
die aktuellen Arbeitsgewichte und die Einstellungen.

**Importieren:** Tab **Mehr › Backup importieren**, dann die JSON-Datei auswählen.
Der Import **ersetzt** den lokalen Stand vollständig, er fügt nichts zusammen. Ein
laufendes, noch nicht abgeschlossenes Training wird dabei verworfen. So zieht man den
Stand auch auf ein neues Gerät um: auf dem alten exportieren, auf dem neuen importieren.

Dateien aus fremden Quellen werden abgewiesen – akzeptiert wird nur ein Export
dieser App.

## Aufbau

| Datei | Zweck |
|---|---|
| `index.html` | komplette App: UI, Logik, Trainingspläne |
| `sw.js` | Service Worker, cached die App-Shell für den Offline-Betrieb |
| `manifest.webmanifest` | PWA-Manifest (Name, Icons, Standalone-Modus) |
| `icon-192.png`, `icon-512.png` | Manifest-Icons |
| `apple-touch-icon.png` | Home-Bildschirm-Icon unter iOS |
| `.nojekyll` | schaltet die Jekyll-Verarbeitung auf GitHub Pages ab |

Alle Pfade sind relativ, die App läuft daher sowohl unter einer eigenen Domain als
auch in einem Unterordner.

## Update ausrollen

Änderungen committen und pushen. Wird dabei eine der gecachten Dateien angefasst,
muss in `sw.js` die Konstante `CACHE` hochgezählt werden (`training-v1` →
`training-v2`), sonst behalten bereits installierte Geräte die alte Version.
