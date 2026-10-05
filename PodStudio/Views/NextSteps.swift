import GroupActivities
import StudioCore
import StudioServices
import SwiftUI

/// Shown on a fresh session: what to do now, in order. Disappears once recording started.
struct NextStepsPanel: View {
    @Environment(StudioController.self) private var studio
    @Binding var dismissed: Bool

    private var visible: Bool {
        !dismissed
            && studio.transport.phase == .idle
            && studio.current?.state == .idle
            && studio.exportedFiles.isEmpty
    }

    var body: some View {
        if visible {
            ArcadeSection(title: studio.isOwner ? "So geht es weiter" : "Gleich geht es los", accent: Arcade.accent) {
                if studio.isOwner { ownerSteps } else { guestSteps }
                Button("Verstanden, ausblenden") { withAnimation { dismissed = true } }
                    .buttonStyle(.arcade(.ghost, compact: true))
            }
        }
    }

    @ViewBuilder private var ownerSteps: some View {
        let live = studio.isInSharePlay || studio.sharePlay.remoteParticipantCount > 0
        step(1, "Drehbuch schreiben", "Im Tab „Drehbuch“. Optional: ohne Drehbuch geht es auch.", done: false)
        step(2, "Mikrofon prüfen", "Sprich einmal und schau, ob der Pegel ausschlägt.", done: studio.capture.isRunning) {
            if !studio.capture.isRunning {
                Button("Mikrofon starten") {
                    do { try studio.capture.start() } catch { studio.errorMessage = error.localizedDescription }
                }
                .buttonStyle(.arcade(.primary, compact: true))
            }
        }
        if let session = studio.current {
            step(3, "Gäste einladen", "Der Link kommt per Nachrichten oder FaceTime. Allein aufnehmen geht auch.", done: live) {
                ShareLink(item: studio.activity(for: session), preview: SharePreview("PodStudio: \(session.title)")) {
                    Text("Einladen")
                }
                .buttonStyle(.arcade(.primary, compact: true))
            }
        }
        step(4, "REC drücken", "Unten startet die Aufnahme auf allen Geräten gleichzeitig. Danach liegen alle Spuren unter „Material“.", done: false)
    }

    @ViewBuilder private var guestSteps: some View {
        step(1, "Mikrofon prüfen", "Sprich einmal und schau, ob der Pegel ausschlägt.", done: studio.capture.isRunning) {
            if !studio.capture.isRunning {
                Button("Mikrofon starten") {
                    do { try studio.capture.start() } catch { studio.errorMessage = error.localizedDescription }
                }
                .buttonStyle(.arcade(.primary, compact: true))
            }
        }
        step(2, "Auf den Host warten", "Er startet die Aufnahme, bei dir läuft sie dann automatisch mit.", done: false)
        step(3, "Spur wird hochgeladen", "Nach dem Stopp geht deine Aufnahme von allein per iCloud an den Host.", done: false)
    }

    private func step(_ n: Int, _ title: String, _ text: String, done: Bool,
                      @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(done ? "OK" : "\(n)")
                .font(Arcade.chrome(15, weight: .heavy))
                .foregroundStyle(Arcade.accentInk)
                .frame(width: 36, height: 36)
                .background(done ? Arcade.ok : Arcade.accent)
                .overlay(Rectangle().strokeBorder(Arcade.accentInk, lineWidth: 2))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Arcade.read(.headline)).foregroundStyle(Arcade.ink)
                Text(text).font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
    }
}
