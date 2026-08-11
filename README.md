# Training

Persönlicher Trainingsplan-Tracker als installierbare PWA. Statisches HTML, CSS und
JavaScript – kein Build-Schritt, keine Abhängigkeiten, kein Server, kein Konto,
kein Tracking.

## Was die App macht

- **Heute** – zeigt die für den Wochentag geplante Einheit (Push, Pull, Beine im
  A/B-Wechsel), startet das Training, zählt Sätze und Wiederholungen mit und blendet
  nach jedem Satz einen Pausentimer ein. Der Timer läuft auf Zeitstempel, überlebt
  also Hintergrund, Bildschirmsperre und App-Neustart.
- **Duell gegen das letzte Mal** – während der Einheit rechnet die App die bewegte
  Tonnage laufend gegen dieselbe Einheit beim letzten Mal und zeigt den Abstand in
  Prozent. Pro Übung steht darunter, was letztes Mal geschafft wurde.
- **Automatische Gewichtssteuerung** – alle Sätze im Zielbereich bedeutet Gewicht
  rauf, dreimal in Folge unter dem Ziel bedeutet 10 % runter. Gesteigert wird in der
  Stufe, die das Gerät zulässt: 1 kg am Kabelzug, 1,25 kg an Scheiben.
- **Scheiben-Rechner** – bei Klimmzügen und Dips rechnet die App aus dem eingestellten
  Zusatzgewicht, welche Scheiben auf den Gürtel müssen.
- **Verlauf** – Monatskalender mit farbig markierten Trainingstagen. Jede Einheit ist
  antippbar und öffnet die volle Auswertung: alle Sätze, Tonnage, Dauer, Vergleich zur
  vorigen gleichen Einheit.
- **Übungsverlauf** – jede Übung antippbar, mit Kurve des geschätzten 1RM über alle
  Einheiten und Einzelauflistung.
- **Fortschritt** – Ziele als Etappen statt als unerreichbarer Endwert, Einheiten pro
  Kalenderwoche gegen ein Wochenziel, Gesamtzahlen und Rekorde.
- **Ausgefallene Übungen** – Übung mit Grund als ausgefallen markieren (Gerät belegt,
  Schmerzen …). Sie landet in der Nachhol-Liste und wird beim nächsten passenden
  Training automatisch angehängt.
- **Pro Seite oder Gesamt** – pro Übung einstellbar, dazu Zusatzlast für exzentrische
  Betonung und Kette sowie ein freier Variantenname.
- **Plan-Editor** – Übungen tauschen, hinzufügen, entfernen, umsortieren, Sätze,
  Wiederholungsbereiche und Gewichtsschritte anpassen.

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

**Einspielen:** Tab **Mehr › Backup einspielen**, dann die JSON-Datei auswählen.
Danach fragt die App, was passieren soll:

- **Zusammenführen** – ergänzt nur die Einheiten, die auf diesem Gerät fehlen.
  Erkennt Duplikate an ID sowie an Datum und Plan. Nichts geht verloren.
- **Ersetzen** – verwirft den lokalen Stand komplett und übernimmt die Datei.

So zieht man den Stand auf ein neues Gerät um: auf dem alten exportieren, auf dem
neuen einspielen.

Dateien aus fremden Quellen werden abgewiesen – akzeptiert wird nur ein Export
dieser App.

## Fremdmaterial

Die Körpergrafik der Muskelgruppen-Anzeige stammt aus
[Body Muscles](https://github.com/vulovix/body-muscles) von Viktor Vulovic,
lizenziert unter der Apache License 2.0. Übernommen wurden ausschließlich die
SVG-Pfaddaten der Muskelregionen; gerendert und eingefärbt wird mit eigenem Code.

Die Übungszeichnungen stammen aus [Everkinetic](https://github.com/everkinetic/data),
lizenziert unter CC BY-SA 4.0. Je Übung sind zwei Vektorbilder eingebettet —
entspannte und angespannte Position. Die Füllebene wurde entfernt, damit die
Linien der Textfarbe folgen; die Pfade selbst sind unverändert.

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

Änderungen committen und pushen, GitHub Pages baut automatisch.

Das HTML-Dokument wird vom Service Worker **network first** ausgeliefert: mit Netz
kommt immer die aktuelle Version, ohne Netz die letzte gecachte. Ein Update ist
deshalb schon beim ersten Neustart der App da und nicht erst beim zweiten.

Zwei Dinge beim Ausrollen mitziehen:

- `APP_VERSION` in `index.html` hochzählen. Der Wert steht in der App unter
  **Mehr › Version** und ist der einzige verlässliche Weg, am Gerät zu sehen,
  welcher Stand wirklich läuft.
- `CACHE` in `sw.js` hochzählen, wenn Icons oder Manifest angefasst wurden. Diese
  Dateien werden weiterhin cache-first ausgeliefert.

Wenn ein Gerät trotzdem hängt: **Mehr › Auf Update prüfen** fragt aktiv beim Server
nach, übernimmt einen wartenden Service Worker und startet die App neu.
