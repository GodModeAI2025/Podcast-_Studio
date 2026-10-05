# Abnahme

Legende: ✅ automatisiert verifiziert · 🧪 Unit-Test vorhanden · 📱 manuell auf Gerät ausstehend

## Loop 1 — Solo-Studio

- [x] Projekt: Multiplatform (iOS + macOS), SwiftUI, Swift 6, Capabilities Group Activities + iCloud (+ Push)
- [x] Mic-Auswahl, Voice Processing, Mic-Modes-Picker, AirPods-HQ-Option, Level-Metering
- [x] Lokale Aufnahme PCM 48 kHz / 24 Bit (crash-sicheres WAV) → ALAC
- [x] MP3-Export (LAME 3.100, CBR 128–192 kbps, Mono/Stereo, ID3v2) 🧪

| Kriterium | Stand |
|---|---|
| 10 min Aufnahme auf iPhone und Mac | 📱 |
| MP3 ohne Fehler, in Audacity öffnen | ✅ Encoder-Test prüft Frame-Header (MPEG-1 L3, 128 kbps, 48 kHz); ffmpeg dekodiert fehlerfrei · 📱 Audacity |
| Kein Clipping | ✅ Limiter-Ceiling -1,5 dBFS (Test); nach MP3 gemessen ≤ -1,0 dBFS |
| LUFS ~ -16 | ✅ ffmpeg `ebur128` auf den `pstool`-Exporten: -16,5 … -17,1 LUFS (MP3), -16,0 … -16,3 vor dem Encoding |

Prüfstand: `swift run -c release pstool synth …` + `pstool render …` (siehe README).

## Loop 2 — Session + Drehbuch

- [x] `PodcastSessionActivity` + Einladung per `ShareLink` (Nachrichten) bzw. `activate()` im FaceTime-Call
- [x] Messenger-Sync: Drehbuch (höchste Revision gewinnt 🧪), Leseposition, REC mit gemeinsamem Zeitstempel 🧪
- [x] Markdown-Rendering (Block-Parser 🧪 + `AttributedString` inline), Abschnitts-Highlight, Auto-Scroll

| Kriterium | Stand |
|---|---|
| Einladung < 30 s über Mobilfunk | 📱 |
| Drehbuch-Update < 2 s | 📱 (Debounce 250 ms + Messenger-Latenz) |
| REC-Start-Differenz ≤ 1 Frame | 🧪 Ausführung sample-genau (`CaptureSchedulerTests`); Restfehler = Uhren-Offset, angezeigt als „Uhr-Sync ±x ms“ · 📱 Messung mit Klatschtest |

## Loop 3 — Materialtransfer

- [x] Zone + zone-weite CKShare, Upload als `TrackRecord` mit `CKAsset`, Retry mit Backoff 🧪
- [x] `CKDatabaseSubscription` → Silent Push → Fetch → „X von N Tracks da“ 🧪 (Statusmodell)
- [x] Zone löschen nach Export

| Kriterium | Stand |
|---|---|
| 2 Teilnehmer laden hoch, Owner-App geschlossen → Push → 2/2 | 📱 (iOS weckt keine vom Nutzer beendete App; Abgleich beim Öffnen) |
| Zone löschen → Quota frei | 📱 |

## Loop 4 — Mix + Multi-Track-Export

- [x] Import (beliebige Core-Audio-Formate → 48 kHz mono), Alignment über REC-Fenster + Segmente 🧪
- [x] Offline-Rendering (AVAudioEngine manual rendering: HPF 80 Hz, EQ, Dynamics)
- [x] Loudness -16 LUFS je Sprecher + Summe, Limiter 🧪

| Kriterium | Stand |
|---|---|
| 3 Tracks → 3 MP3 + 1 Summe | ✅ `pstool render` |
| Pegeldifferenz < 2 dB | ✅ Eingänge -6/-20/-32 dB → Ausgänge -16,1 … -16,3 LUFS (vor MP3) bzw. -16,5 … -17,1 (MP3, ffmpeg); Test `testPipelineSpeakerLevelsWithin2dB` |

## Loop 5 — Härten

- [x] Crash-Recovery: WAV-Header-Reparatur, offenes Segment schließen, Status `recovered` 🧪
- [x] Hintergrundaufnahme (`UIBackgroundModes: audio`), Unterbrechungen (Anruf) → Segmentgrenze + Neustart der Engine
- [x] Upload-Retry (`RetryPolicy`, `CKError.retryAfterSeconds`) 🧪, Upload später manuell erneut auslösbar
- [ ] Metering-Kalibrierung gegen Referenzpegel 📱

| Kriterium | Stand |
|---|---|
| App während Aufnahme killen → Recovery beim Start | 🧪 Recovery-Scan · 📱 |
| Flugmodus während Session → Aufnahme unbeeinträchtigt | Architektur: Aufnahme ist rein lokal · 📱 |
