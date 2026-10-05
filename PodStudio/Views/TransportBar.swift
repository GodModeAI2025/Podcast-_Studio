import StudioCore
import StudioServices
import SwiftUI

/// REC / Pause / Stop / Marker — synchronised: every device executes the command at the
/// same shared-clock time.
struct TransportBar: View {
    @Environment(StudioController.self) private var studio
    @State private var markerNote = ""
    @State private var showMarker = false

    var body: some View {
        HStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                HStack(spacing: 8) {
                    Circle()
                        .fill(studio.transport.phase == .recording ? Color.red : Color.secondary.opacity(0.4))
                        .frame(width: 10, height: 10)
                    Text(format(studio.elapsed))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .contentTransition(.numericText())
                }
            }
            .frame(minWidth: 130, alignment: .leading)

            Spacer()

            if studio.transport.phase == .idle {
                Button { studio.issue(.start) } label: {
                    Label("Aufnahme", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!studio.canIssue(.start))
                .keyboardShortcut("r", modifiers: .command)
            }
            if studio.transport.phase == .recording {
                Button { studio.issue(.pause) } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(.bordered)
            }
            if studio.transport.phase == .paused {
                Button { studio.issue(.resume) } label: { Label("Fortsetzen", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            if studio.transport.phase == .recording || studio.transport.phase == .paused {
                Button { studio.issue(.stop) } label: { Label("Stopp", systemImage: "stop.fill") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(".", modifiers: .command)
                Button { showMarker = true } label: { Label("Marker", systemImage: "bookmark") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("m", modifiers: .command)
            }
            if studio.transport.phase == .stopped || studio.current?.state == .finished {
                Label("Aufnahme beendet", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .labelStyle(.titleAndIcon)
        .alert("Marker setzen", isPresented: $showMarker) {
            TextField("Notiz (optional)", text: $markerNote)
            Button("Setzen") {
                studio.addMarker(markerNote)
                markerNote = ""
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
