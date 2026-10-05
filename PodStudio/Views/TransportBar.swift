import StudioCore
import StudioServices
import SwiftUI

/// REC / Pause / Stop / Marker — synchronised: every device executes the command at the
/// same shared-clock time. Styled as the `.lp-score` strip: big yellow digits on dark blue.
struct TransportBar: View {
    @Environment(StudioController.self) private var studio
    @State private var markerNote = ""
    @State private var showMarker = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Arcade.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                if let reason = studio.startBlockReason {
                    Text(reason)
                        .font(Arcade.read(.footnote))
                        .foregroundStyle(Arcade.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 18) {
                    timer
                    if isPhone {
                        Spacer(minLength: 4)
                        Eyebrow(phaseLabel, color: studio.transport.phase == .recording ? Arcade.rec : Arcade.muted)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Eyebrow(phaseLabel, color: studio.transport.phase == .recording ? Arcade.rec : Arcade.muted)
                            Text("48 kHz · 24 Bit")
                                .font(Arcade.chrome(12))
                                .foregroundStyle(Arcade.muted)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        buttons
                    }
                }
                // iPhone: the controls get their own full-width row, so labels never truncate.
                if isPhone { buttons }
            }
            .padding(.horizontal, isPhone ? 16 : 22)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Arcade.bar)
        }
        .alert("Marker setzen", isPresented: $showMarker) {
            TextField("Notiz (optional)", text: $markerNote)
            Button("Setzen") {
                studio.addMarker(markerNote)
                markerNote = ""
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            HStack(spacing: 12) {
                RecLamp(active: studio.transport.phase == .recording)
                Text(format(studio.elapsed))
                    .font(Arcade.chrome(30, weight: .heavy, relativeTo: .title))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(studio.transport.phase == .recording ? Arcade.accent : Arcade.ink)
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch studio.transport.phase {
            case .idle:
                Button("● Rec") { studio.issue(.start) }
                    .buttonStyle(.arcade(.rec, fill: isPhone))
                                        .disabled(!studio.canIssue(.start))
                    .keyboardShortcut("r", modifiers: .command)
                    .help(studio.canIssue(.start) ? "Aufnahme auf allen Geräten starten" : "Warte auf Uhren-Sync bzw. Session ist bereits aufgenommen")
            case .recording:
                Button("Marker") { showMarker = true }
                    .buttonStyle(.arcade(.ghost, fill: isPhone))
                                        .keyboardShortcut("m", modifiers: .command)
                Button("Pause") { studio.issue(.pause) }
                    .buttonStyle(.arcade(.primary, fill: isPhone))
                                    Button("■ Stopp") { studio.issue(.stop) }
                    .buttonStyle(.arcade(.danger, fill: isPhone))
                                        .keyboardShortcut(".", modifiers: .command)
            case .paused:
                Button("Marker") { showMarker = true }
                    .buttonStyle(.arcade(.ghost, fill: isPhone))
                                    Button("● Weiter") { studio.issue(.resume) }
                    .buttonStyle(.arcade(.rec, fill: isPhone))
                                    Button("■ Stopp") { studio.issue(.stop) }
                    .buttonStyle(.arcade(.danger, fill: isPhone))
                                case .stopped:
                Text("Aufnahme beendet")
                    .font(Arcade.chrome(13, weight: .heavy))
                    .foregroundStyle(Arcade.ok)
            }
        }
            }

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var phaseLabel: String {
        switch studio.transport.phase {
        case .idle: return studio.current?.state == .finished ? "Fertig" : "Bereit"
        case .recording: return "Aufnahme läuft"
        case .paused: return "Pausiert"
        case .stopped: return "Gestoppt"
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

/// Square REC lamp that blinks while recording.
private struct RecLamp: View {
    let active: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = active && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            Circle()
                .fill(on ? Arcade.rec : Arcade.rec.opacity(active ? 0.35 : 0.15))
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel(active ? "Aufnahme läuft" : "Keine Aufnahme")
    }
}
