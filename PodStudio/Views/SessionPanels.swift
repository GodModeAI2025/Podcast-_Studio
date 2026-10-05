import StudioCore
import StudioServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SessionStatusPanel: View {
    @Environment(StudioController.self) private var studio

    private var people: [ParticipantInfo] {
        Array(studio.participants.values).sorted {
            $0.isOwner != $1.isOwner ? $0.isOwner : $0.displayName < $1.displayName
        }
    }

    var body: some View {
        ArcadeSection(title: "Session") {
            HStack(alignment: .top) {
                ScoreView(value: "\(people.count)", label: "Stimmen")
                Spacer()
                ScoreView(value: "\(studio.current?.markers.count ?? 0)", label: "Marker", color: Arcade.line)
                Spacer()
                ScoreView(value: clockValue, label: "Uhr-Sync",
                          color: studio.isOwner || studio.clock.isSynchronized ? Arcade.ok : Arcade.warn)
            }
            Rectangle().fill(Arcade.hairline).frame(height: 1)
            ForEach(Array(people.enumerated()), id: \.element.id) { index, p in
                HStack(spacing: 12) {
                    Monogram(name: p.displayName, color: SpeakerColors.color(for: index))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.displayName + (p.id == studio.identity.id ? " (ich)" : ""))
                            .font(Arcade.read(.body).weight(.semibold))
                            .foregroundStyle(Arcade.ink)
                        Text([p.isOwner ? "Host" : "Gast", platform(p.platform)].joined(separator: " · "))
                            .font(Arcade.chrome(12))
                            .foregroundStyle(Arcade.muted)
                    }
                    Spacer()
                    deliveryBadge(for: p.id)
                }
            }
        }
    }

    private var clockValue: String {
        if studio.isOwner { return "REF" }
        guard let u = studio.clock.uncertainty else { return "--" }
        return String(format: "%.0fms", u * 1000)
    }

    private func platform(_ p: DevicePlatform) -> String {
        switch p {
        case .iOS: return "iPhone/iPad"
        case .macOS: return "Mac"
        case .other: return "Gerät"
        }
    }

    @ViewBuilder private func deliveryBadge(for id: UUID) -> some View {
        switch studio.deliveryStatus.states[id] ?? .waiting {
        case .waiting: EmptyView()
        case .uploading(let f): Badge(text: "\(Int(f * 100))%", color: Arcade.line)
        case .available: Badge(text: "Cloud", color: Arcade.line)
        case .downloaded: Badge(text: "Da", color: Arcade.ok)
        case .failed: Badge(text: "Fehler", color: Arcade.accentHot)
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Arcade.chrome(12, weight: .heavy))
            .foregroundStyle(Arcade.accentInk)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color))
    }
}

/// Arcade progress bar: cyan frame, yellow fill.
struct ArcadeProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Arcade.field)
                Capsule().fill(Arcade.accent).frame(width: max(14, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 12)
        .accessibilityValue("\(Int(value * 100)) Prozent")
    }
}

/// Owner: "X von N Tracks da", mix & export, zone cleanup. Participant: upload status.
struct DeliveryPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        ArcadeSection(title: "Material", accent: studio.isOwner ? Arcade.accent : nil) {
            if studio.isOwner { ownerContent } else { participantContent }
        }
    }

    @ViewBuilder private var ownerContent: some View {
        let status = studio.deliveryStatus
        HStack(alignment: .center) {
            ScoreView(value: "\(status.deliveredCount)/\(status.expectedCount)", label: "Tracks da",
                      color: status.isComplete ? Arcade.ok : Arcade.accent)
            Spacer()
            Button("↻") { Task { await studio.refreshDelivery() } }
                .buttonStyle(.arcade(.ghost, compact: true))
                .help("iCloud-Zone abfragen")
        }
        ArcadeProgress(value: status.overallProgress)

        if let progress = studio.exportProgress {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(progress.step, color: Arcade.accent)
                ArcadeProgress(value: progress.fraction)
            }
        } else {
            Button("Mischen & MP3 exportieren") { Task { await studio.mixAndExport() } }
                .buttonStyle(.arcade)
                .disabled(studio.mixableTracks.isEmpty || studio.isRecordingActive)
        }

        if !studio.exportedFiles.isEmpty {
            Rectangle().fill(Arcade.hairline).frame(height: 1)
            ForEach(studio.exportedFiles) { file in
                HStack(spacing: 10) {
                    Text(file.url.pathExtension.uppercased())
                        .font(Arcade.chrome(10, weight: .heavy))
                        .foregroundStyle(Arcade.accentInk)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(file.speaker == nil ? Arcade.accent : Arcade.line)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.url.deletingPathExtension().lastPathComponent)
                            .font(Arcade.read(.callout)).foregroundStyle(Arcade.ink).lineLimit(1)
                        if file.loudnessLUFS.isFinite {
                            Text(String(format: "%.1f LUFS · Peak %.1f dBFS", file.loudnessLUFS, file.peakDB))
                                .font(Arcade.chrome(12)).foregroundStyle(Arcade.muted)
                        }
                    }
                    Spacer()
                    ShareLink(item: file.url) { Text("Teilen") }
                        .buttonStyle(.arcade(.ghost, compact: true))
                }
            }
            #if os(macOS)
            Button("Im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting(studio.exportedFiles.map(\.url))
            }
            .buttonStyle(.arcade(.ghost, compact: true))
            #endif
        }

        if studio.current?.deliveryZoneName != nil {
            Rectangle().fill(Arcade.hairline).frame(height: 1)
            Button("iCloud-Zone löschen") { Task { await studio.deleteDeliveryZone() } }
                .buttonStyle(.arcade(.danger, compact: true))
                .disabled(studio.exportedFiles.isEmpty)
            Text("Gibt den iCloud-Speicher frei. Aufnahmen und Exporte bleiben lokal. Erst nach dem Export möglich.")
                .font(Arcade.read(.caption)).foregroundStyle(Arcade.muted)
        }
    }

    @ViewBuilder private var participantContent: some View {
        let ready = studio.current?.state == .finished || studio.current?.state == .recovered
        switch studio.uploadState {
        case .idle:
            Text(ready ? "Deine Spur ist bereit zum Hochladen."
                       : "Nach der Aufnahme geht deine Spur automatisch an den Host.")
                .font(Arcade.read(.callout)).foregroundStyle(Arcade.ink)
            if ready {
                Button("Jetzt hochladen") { Task { await studio.uploadLocalTrack() } }
                    .buttonStyle(.arcade)
            }
        case .waitingForShare:
            Eyebrow("Warte auf iCloud-Freigabe des Hosts …", color: Arcade.warn)
        case .uploading(let f):
            ScoreView(value: "\(Int(f * 100))%", label: "Upload")
            ArcadeProgress(value: f)
        case .done:
            ScoreView(value: "OK", label: "Spur beim Host", color: Arcade.ok)
        case .failed(let message):
            Text(message).font(Arcade.read(.callout)).foregroundStyle(Arcade.warn)
            Button("Erneut versuchen") { Task { await studio.uploadLocalTrack() } }
                .buttonStyle(.arcade)
        }
    }
}
