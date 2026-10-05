# Architektur

Grundlage ist die Agent-Build-Spezifikation „PodStudio“. Dieses Dokument beschreibt, wie sie
umgesetzt wurde, wo bewusst abgewichen oder präzisiert wurde und was noch offen ist.

## Datenfluss

```
            ┌────────────── SharePlay (GroupSessionMessenger, reliable, E2E) ──────────────┐
            │ hello · script(rev) · scriptPosition · record(action, sharedTime, take)        │
            │ marker · clockPing/Pong · deliveryShare(url) · uploadProgress · trackDelivered │
            ▼                                                                                ▼
 Owner ── StudioController ──────────────────────────────────── StudioController ── Teilnehmer
   │  AudioCaptureEngine → TrackRecorder → CaptureScheduler → CrashSafeWAVWriter (48k/24)  │
   │  Stopp: WAV → ALAC (.caf)                                     Stopp: WAV → ALAC      │
   │                                                                     │                 │
   │  CloudKit: private DB, Zone "Session-<UUID>", CKShare(zone, readWrite)◄── CKAsset-Upload
   │  CKDatabaseSubscription → Silent Push → Zone-Fetch → "X von N Tracks da"
   ▼
 PostProductionEngine: Import → TimelineAligner → AVAudioEngine offline (HPF/EQ/Dynamics)
   → LoudnessNormalizer (-16 LUFS, Limiter -1.5 dBFS) → Summe → LAME-MP3 je Sprecher + Mix
```

## Architektur-Entscheidungen

AD1–AD6 aus der Spezifikation gelten unverändert. Zusätzlich:

| # | Entscheidung | Grund |
|---|---|---|
| AD7 | **Gemeinsame Uhr = Host-Uhr des Owners**, NTP-artiger Ping/Pong über den Messenger, Auswahl der Samples mit kleinster RTT (`ClockSynchronizer`) | `GroupSession` bietet keine gemeinsame Uhr; `ProcessInfo.systemUptime` hat dieselbe Basis wie `AVAudioTime.hostTime` |
| AD8 | **REC-Befehle werden in die Zukunft terminiert** (`sharedNow + 0,75 s`) und von jedem Gerät **sample-genau im Audio-Stream** ausgeführt (`CaptureScheduler`) | Netzwerklatenz und Puffergrößen spielen keine Rolle; Startfehler = Fehler der Uhrensynchronisation (typ. < 10 ms) |
| AD9 | Segmente werden in **lokaler** Zeit gestempelt; die beste Offset-Schätzung wird mitgespeichert und erst bei Upload/Mix angewendet (`TrackInfo.clockOffset`) | Aufnahme darf vor Konvergenz der Uhren starten, ohne dass das Alignment leidet |
| AD10 | **Pausen erzeugen Fenster** (`RecordingWindow`); der `TimelineAligner` schneidet Pausen heraus und richtet jedes Segment über seinen Startzeitpunkt aus | Pause/Resume auf allen Geräten konsistent, Spät-Joiner und Unterbrechungen (Anruf) werden korrekt platziert |
| AD11 | Aufnahme als **crash-sicheres WAV** (Header-Update + fsync jede Sekunde), nach Stopp Konvertierung zu **ALAC** und Längenvergleich vor dem Löschen | Spez.: „PCM intern, ALAC persistiert“ + „kein Datenverlust bei Crash“. Ein abgebrochenes CAF/ALAC lässt sich nicht zuverlässig reparieren |
| AD12 | **Zone-weite CKShare** mit `publicPermission = .readWrite`; die URL wird **nur** über den Ende-zu-Ende-verschlüsselten SharePlay-Messenger verteilt | Teilnehmer brauchen keine Apple-ID-Lookup-Einladung; die Zone wird nach dem Mix gelöscht |
| AD13 | DSP-Kette doppelt vorhanden: **AVAudioEngine offline** auf dem Gerät (Spez.), identische **Pure-Swift-Kette** (`VoiceChain`) als Fallback und für Tests/`pstool` | Verifizierbarkeit ohne Gerät; Loudness/Limiter/Mix sind ohnehin plattformunabhängig |
| AD14 | Jeder darf REC/Pause/Stopp/Marker auslösen; doppelte Befehle werden über die Zustandsmaschine (`TransportState`) verworfen | „steuern die Aufnahme gemeinsam“ |

## Präzisierungen und Abweichungen

* **`AVAudioUnitCompressor` gibt es nicht.** Verwendet wird `AVAudioUnitEffect` mit Apples
  `kAudioUnitSubType_DynamicsProcessor` (Threshold, Headroom, Attack, Release).
* **`CKDatabaseSubscription(recordType:)`** gibt es so nicht: Die Subscription wird mit
  `subscriptionID` angelegt, `recordType` als Property gesetzt, `shouldSendContentAvailable = true`.
* **Mikrofonauswahl:** Unter iOS über `AVAudioSession.availableInputs`/`setPreferredInput`, unter
  macOS über Core Audio (`kAudioOutputUnitProperty_CurrentDevice`). `AVAudioApplication` liefert die
  Aufnahmeberechtigung.
* **Summen-Mix:** Die Stimmen werden einzeln per AVAudioEngine offline gerendert, einzeln auf
  -16 LUFS normalisiert und dann addiert (die Summe wird nochmals normalisiert). So gilt das
  Kriterium „Pegeldifferenz < 2 dB“ per Konstruktion.
* **Mono-Loudness:** Mono wird nach BS.1770 als ein Kanal mit Gewicht 1 gemessen (wie ffmpeg
  `ebur128`). Die Zielgröße ist in `ExportOptions.loudness` konfigurierbar.
* **MP3-Codec-Verlust:** LAME senkt die integrierte Lautheit je nach Material um ~0,3–0,8 dB
  (gemessen mit ffmpeg an synthetischem Material). Bei Bedarf Ziel auf -15,5 LUFS setzen.
* **Swift 6:** StudioCore, LAMEKit und die App laufen im Swift-6-Sprachmodus. `StudioServices` ist
  vorerst im Swift-5-Modus (`swiftLanguageMode(.v5)`), weil AVFoundation/GroupActivities/CloudKit
  noch nicht vollständig für Strict Concurrency annotiert sind. Umstellen, sobald der Build
  warnungsfrei ist.

## Gestaltung

Optik und Layout lehnen sich an „Think Different, Think AI“ an (`docs/base.css`,
`docs/landing.css` im Repo godmodeai2025/ThinkDifferentThinkAI) und sind in
`PodStudio/Theme/Arcade.swift` als Tokens und Bausteine umgesetzt:

* Farben 1:1 aus `:root` (`--bg #051a7a`, `--panel #071d8f`, `--ink #d8f8ff`, `--line #34d4ff`,
  `--accent #ffcf24`, `--accent-hot #ff7a1a`, `--accent-ink #06145f`), immer Dark Mode.
* Hintergrund: 135°-Verlauf mit cyanfarbenen Scanlines (2 px / 8 px) und gelbem 96-px-Raster.
* „Chrome“-Schrift Courier New in Versalien für Überschriften, Labels, Kennzahlen und Buttons;
  Fließtext (Drehbuch) in der proportionalen Systemschrift — wie auf der Website.
* Panels (`.lp-card`) mit 4-px-Cyan-Kante und harten, unscharfen Schlagschatten; eckige Ecken.
* Buttons (`.lp-btn`): gelber Block, dunkle 3-px-Kante, Schatten, der beim Drücken einrastet;
  REC als roter Block, Ghost-Variante mit Cyan-Kante.
* Kennzahlen (`.lp-score`): Timecode, „2/3 Tracks da“, Stimmen und Uhr-Sync als große gelbe Ziffern.
* Zitate im Drehbuch als `.lp-quote`-Karte mit farbiger Oberkante; Monogramme je Sprecher.

## Offene Prüfpunkte

| # | Punkt | Stand |
|---|---|---|
| O1 | MMCS für In-App-Video-Grid (Spez. §8.1) | offen; Basis-Architektur unberührt |
| O2 | Video-Aufnahme (Spez. §8.2) | **entschieden: kein Video.** Es wird nur Audio aufgenommen und exportiert; die Kamera dient ausschließlich als Selbstansicht (Preset `.medium`, kein Writer) |
| O3 | Co-Editing Drehbuch (Spez. §8.3) | MVP: nur Owner editiert |
| O4 | **LAME-Lizenz (LGPL)** bei statischem Linken im App Store | **vor Release klären**: Relinking ermöglichen (Objektdateien bereitstellen) oder LAME als dynamisches Framework ausliefern |
| O5 | Gleichzeitige Mikrofonnutzung durch FaceTime und App während SharePlay | auf Gerät verifizieren; Voice Processing + `.videoChat` ist dafür ausgelegt. Fallback: SharePlay über Nachrichten ohne FaceTime-Call |
| O6 | iOS-26-Symbole `.allowBluetoothHFP`, `.bluetoothHighQualityRecording` | beim ersten Build verifizieren; ggf. auf `.allowBluetooth` zurückfallen |
| O7 | Silent Push weckt keine vom Nutzer beendete App (iOS-Verhalten) | Abfangen: Abfrage beim Wechsel in den Vordergrund (`scenePhase == .active`) |
| O8 | Kamera parallel zu FaceTime | `isMultitaskingCameraAccessEnabled` gesetzt; auf Gerät verifizieren |
