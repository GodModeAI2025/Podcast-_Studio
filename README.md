# PodStudio

Native, Apple-only Podcast-Studio-App (iOS 26+ / macOS 26+) nach dem Riverside-Prinzip:
Jedes Gerät nimmt **lokal in Studioqualität** auf (48 kHz / 24 Bit). Das Internet trägt nur
Live-Kommunikation (SharePlay/FaceTime), Sync (Drehbuch, REC-Befehle, Marker) und am Ende den
Transfer der Tracks per CloudKit zum Owner. Der Owner mischt und exportiert **eine MP3 je
Sprecher + eine Summen-MP3** bei ~ -16 LUFS. Ein eigenes Backend gibt es nicht.

## Projektstruktur

```
PodStudio.xcodeproj           Multiplatform-App-Target (iOS + macOS), Xcode 26
PodStudio/                    SwiftUI-App (synchronisierte Gruppe, neue Dateien werden automatisch erkannt)
  PodStudioApp.swift, AppDelegate.swift (Silent Push)
  Views/                      Studio, Drehbuch, Mikrofon, Session-Status, Material/Export, Transport
Config/                       Info.plist, Entitlements (iOS/macOS), PodStudio.xcconfig (Bundle-ID, Team)
Packages/PodStudioKit/        Swift Package mit der gesamten Logik
  Sources/StudioCore          plattformunabhängig, auch unter Linux getestet
  Sources/StudioServices      AVFoundation, GroupActivities, CloudKit (nur Apple)
  Sources/LAMEKit + CLAME     MP3-Encoder (LAME 3.100, vendored)
  Sources/pstool              CLI-Prüfstand für Loudness/Export
docs/ARCHITECTURE.md          Architektur, Entscheidungen, Abweichungen, offene Punkte
docs/ACCEPTANCE.md            Abnahme-Checklisten Loop 1–5
```

| Modul (Spezifikation) | Umsetzung |
|---|---|
| M1 StudioUI | `PodStudio/Views/*` |
| M2 SessionService | `StudioServices/Session/PodcastSessionActivity.swift`, `SharePlayService.swift` |
| M3 MessengerService | `StudioCore/Messages.swift` (Codec, 256-KB-Guard), `SharePlayService` (Messenger), `ClockSync.swift` |
| M4 CaptureEngine | `StudioServices/Capture/AudioCaptureEngine.swift` (+ `StudioCore/CaptureScheduler.swift`), `CameraController.swift` |
| M5 DeliveryService | `StudioServices/Delivery/DeliveryService.swift`, `StudioCore/DeliveryStatus.swift` |
| M6 PostProduction | `StudioServices/PostProduction/PostProductionEngine.swift`, `StudioCore/DSP/*` |
| M7 ExportService | `LAMEKit/MP3Encoder.swift`, `CLAME` |
| M8 StorageService | `StudioCore/Storage/*` (Session-Store, crash-sicheres WAV, Recovery-Scan) |
| Orchestrierung | `StudioServices/StudioController.swift` |

## Loslegen (Mac mit Xcode 26)

1. `Config/PodStudio.xcconfig`: `PODSTUDIO_BUNDLE_ID` und `DEVELOPMENT_TEAM` setzen
   (oder eine nicht eingecheckte `Config/Local.xcconfig` anlegen).
2. `PodStudio.xcodeproj` öffnen → Target *PodStudio* → *Signing & Capabilities*: Xcode legt
   die App-ID mit **Group Activities**, **iCloud/CloudKit** (Container `iCloud.<bundle id>`) und
   **Push Notifications** an. Für macOS zusätzlich App Sandbox (Mikrofon, Kamera, ausgehende
   Verbindungen) — ist in `Config/PodStudio-macOS.entitlements` hinterlegt.
3. Einmal im CloudKit Dashboard das Schema prüfen: Record-Typen `PodcastSession` und
   `TrackRecord` entstehen in der Development-Umgebung automatisch beim ersten Lauf. Vor einem
   Release ins Production-Schema deployen.
4. Auf iPhone und Mac starten, Session anlegen, über **Gäste einladen** (ShareLink → Nachrichten)
   einladen.

## Tests ohne Gerät

Die gesamte Kernlogik (Codecs, Revision-Regel, Clock-Sync, sample-genaues REC-Scheduling,
Timeline-Alignment, BS.1770-Loudness, EQ/Kompressor/Limiter, crash-sicheres WAV, Recovery-Scan,
LAME-MP3) läuft auch unter Linux:

```sh
cd Packages/PodStudioKit
swift test                                  # 52 XCTest-Fälle
swift run -c release pstool synth --out /tmp/ps --seconds 60
swift run -c release pstool render --out /tmp/ps/out /tmp/ps/speaker*.wav
ffmpeg -i /tmp/ps/out/mix.mp3 -af ebur128 -f null -   # unabhängige LUFS-Messung
```

Auf dem Mac zusätzlich: `swift test` im Package bzw. ⌘U in Xcode.

## Status

Siehe `docs/ACCEPTANCE.md`. Kurz: Loop-1- bis Loop-5-Funktionen sind implementiert. Die
plattformunabhängigen Teile sind getestet. Der Apple-spezifische Teil (StudioServices, App) wurde
ohne Xcode geschrieben und muss beim ersten Build auf einem Mac verifiziert werden. Die
Abnahmen mit echten Geräten (Mobilfunk, AirPods, Push) stehen aus.
