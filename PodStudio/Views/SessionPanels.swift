import StudioCore
import StudioServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SessionStatusPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("SharePlay", value: sharePlayLabel)
                if !studio.isOwner {
                    LabeledContent("Uhr-Sync", value: clockLabel)
                }
                Divider()
                ForEach(Array(studio.participants.values).sorted { $0.displayName < $1.displayName }) { p in
                    HStack {
                        Image(systemName: p.platform == .macOS ? "laptopcomputer" : p.platform == .iOS ? "iphone" : "person")
                        Text(p.displayName + (p.id == studio.identity.id ? " (ich)" : ""))
                        if p.isOwner { Image(systemName: "crown.fill").foregroundStyle(.yellow) }
                        Spacer()
                        deliveryBadge(for: p.id)
                    }
                    .font(.callout)
                }
                if let markers = studio.current?.markers, !markers.isEmpty {
                    Divider()
                    Text("\(markers.count) Marker").font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Session", systemImage: "person.3")
        }
    }

    private var sharePlayLabel: String {
        switch studio.sharePlay.status {
        case .idle: return "nicht verbunden"
        case .waiting: return "verbinde …"
        case .joined: return "verbunden (\(studio.sharePlay.remoteParticipantCount + 1))"
        case .invalidated: return "beendet"
        }
    }

    private var clockLabel: String {
        guard let u = studio.clock.uncertainty else { return "ausstehend" }
        return String(format: "±%.0f ms", u * 1000)
    }

    @ViewBuilder private func deliveryBadge(for id: UUID) -> some View {
        switch studio.deliveryStatus.states[id] ?? .waiting {
        case .waiting: EmptyView()
        case .uploading(let f): ProgressView(value: f).frame(width: 60)
        case .available: Image(systemName: "icloud.and.arrow.down").foregroundStyle(.blue)
        case .downloaded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Owner: "X von N Tracks da", mix & export, zone cleanup. Participant: upload status.
struct DeliveryPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        GroupBox {
            if studio.isOwner { ownerContent } else { participantContent }
        } label: {
            Label("Material", systemImage: "tray.and.arrow.down")
        }
    }

    @ViewBuilder private var ownerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(studio.deliveryStatus.summary).font(.title3.weight(.semibold))
                Spacer()
                Button { Task { await studio.refreshDelivery() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("iCloud-Zone abfragen")
            }
            ProgressView(value: studio.deliveryStatus.overallProgress)

            if let progress = studio.exportProgress {
                ProgressView(value: progress.fraction) { Text(progress.step).font(.caption) }
            } else {
                Button {
                    Task { await studio.mixAndExport() }
                } label: {
                    Label("Mischen & exportieren (MP3)", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(studio.mixableTracks.isEmpty || studio.isRecordingActive)
            }

            if !studio.exportedFiles.isEmpty {
                Divider()
                ForEach(studio.exportedFiles) { file in
                    HStack {
                        Image(systemName: file.speaker == nil ? "waveform" : "person.wave.2")
                        VStack(alignment: .leading) {
                            Text(file.url.lastPathComponent).font(.callout).lineLimit(1)
                            if file.loudnessLUFS.isFinite {
                                Text(String(format: "%.1f LUFS · Peak %.1f dBFS", file.loudnessLUFS, file.peakDB))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                            .buttonStyle(.borderless)
                    }
                }
                #if os(macOS)
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(studio.exportedFiles.map(\.url))
                }
                #endif
            }

            if studio.current?.deliveryZoneName != nil {
                Divider()
                Button(role: .destructive) {
                    Task { await studio.deleteDeliveryZone() }
                } label: {
                    Label("iCloud-Zone löschen (Speicher freigeben)", systemImage: "icloud.slash")
                }
                .disabled(studio.exportedFiles.isEmpty)
                .help("Aufnahmen bleiben lokal erhalten. Erst nach dem Export möglich.")
            }
        }
    }

    @ViewBuilder private var participantContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch studio.uploadState {
            case .idle:
                Text(studio.current?.state == .finished || studio.current?.state == .recovered
                     ? "Aufnahme bereit zum Hochladen." : "Nach der Aufnahme wird dein Track automatisch an den Host übertragen.")
                    .font(.callout).foregroundStyle(.secondary)
                if studio.current?.state == .finished || studio.current?.state == .recovered {
                    Button("Jetzt hochladen") { Task { await studio.uploadLocalTrack() } }
                }
            case .waitingForShare:
                Label("Warte auf iCloud-Freigabe des Hosts …", systemImage: "hourglass")
            case .uploading(let f):
                ProgressView(value: f) { Text("Lade hoch … \(Int(f * 100)) %") }
            case .done:
                Label("Track beim Host angekommen", systemImage: "checkmark.icloud").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                Button("Erneut versuchen") { Task { await studio.uploadLocalTrack() } }
            }
        }
    }
}
