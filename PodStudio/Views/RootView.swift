import LAMEKit
import StudioCore
import StudioServices
import SwiftUI

struct RootView: View {
    @Environment(StudioController.self) private var studio
    @State private var showNewSession = false
    @State private var newTitle = ""
    @State private var showRecovery = false

    var body: some View {
        @Bindable var studio = studio
        NavigationSplitView {
            SessionListView(showNewSession: $showNewSession)
                .navigationTitle("PodStudio")
        } detail: {
            if studio.current != nil {
                StudioView()
            } else {
                ContentUnavailableView {
                    Label("Keine Session geöffnet", systemImage: "mic.badge.plus")
                } description: {
                    Text("Starte eine neue Session und lade Gäste per SharePlay über Nachrichten oder FaceTime ein.")
                } actions: {
                    Button("Neue Session") { showNewSession = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .alert("Neue Session", isPresented: $showNewSession) {
            TextField("Titel der Folge", text: $newTitle)
            Button("Anlegen") {
                studio.createSession(title: newTitle.isEmpty ? "Neue Folge" : newTitle)
                newTitle = ""
            }
            Button("Abbrechen", role: .cancel) {}
        }
        .alert("Fehler", isPresented: Binding(get: { studio.errorMessage != nil },
                                               set: { if !$0 { studio.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(studio.errorMessage ?? "")
        }
        .alert("Aufnahme wiederhergestellt", isPresented: $showRecovery) {
            Button("OK", role: .cancel) {}
        } message: {
            let seconds = studio.recoveryResults.reduce(Int64(0)) { $0 + $1.recoveredFrames } / 48_000
            Text("PodStudio wurde während einer Aufnahme beendet. \(studio.recoveryResults.count) Aufnahme(n) mit insgesamt \(seconds) s wurden gerettet und können hochgeladen bzw. gemischt werden.")
        }
        .onChange(of: studio.recoveryResults) { _, results in
            showRecovery = !results.isEmpty
        }
    }
}

struct SessionListView: View {
    @Environment(StudioController.self) private var studio
    @Binding var showNewSession: Bool

    var body: some View {
        List(selection: Binding(get: { studio.current?.id }, set: { id in
            if let id, let m = studio.sessions.first(where: { $0.id == id }) { studio.open(m) }
        })) {
            ForEach(studio.sessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    HStack(spacing: 6) {
                        Image(systemName: session.isOwner ? "crown" : "person.wave.2")
                        Text(session.createdAt, style: .date)
                        Text(stateLabel(session.state))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .tag(session.id)
                .contextMenu {
                    Button("Löschen", role: .destructive) { studio.delete(session) }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showNewSession = true } label: { Label("Neue Session", systemImage: "plus") }
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { SettingsView() } label: { Label("Einstellungen", systemImage: "gearshape") }
            }
            #endif
        }
    }

    private func stateLabel(_ s: RecordingState) -> String {
        switch s {
        case .idle: return "bereit"
        case .recording: return "● Aufnahme"
        case .paused: return "pausiert"
        case .finished: return "fertig"
        case .recovered: return "wiederhergestellt"
        }
    }
}

struct SettingsView: View {
    @Environment(StudioController.self) private var studio
    @State private var name = ""

    var body: some View {
        @Bindable var studio = studio
        Form {
            Section("Profil") {
                TextField("Anzeigename", text: $name)
                    .onSubmit { studio.rename(name) }
                    .onDisappear { if !name.isEmpty { studio.rename(name) } }
            }
            Section("Export") {
                Picker("MP3-Bitrate", selection: $studio.exportOptions.mp3.bitrateKbps) {
                    ForEach([128, 160, 192], id: \.self) { Text("\($0) kbps").tag($0) }
                }
                Picker("Kanäle", selection: $studio.exportOptions.mp3.channelMode) {
                    Text("Mono").tag(MP3Settings.ChannelMode.mono)
                    Text("Stereo").tag(MP3Settings.ChannelMode.stereo)
                }
                Toggle("Zusätzlich AAC (M4A)", isOn: $studio.exportOptions.alsoAAC)
                Toggle("Zusätzlich WAV (24 Bit)", isOn: $studio.exportOptions.alsoWAV)
                LabeledContent("Lautheit", value: "\(Int(studio.exportOptions.loudness.integratedLUFS)) LUFS")
            }
            Section("iCloud") {
                LabeledContent("Account", value: accountLabel)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Einstellungen")
        .onAppear { name = studio.identity.displayName }
    }

    private var accountLabel: String {
        switch studio.delivery.accountStatus {
        case .available: return "verfügbar"
        case .noAccount: return "nicht angemeldet"
        case .restricted: return "eingeschränkt"
        case .temporarilyUnavailable: return "vorübergehend nicht verfügbar"
        default: return "unbekannt"
        }
    }
}
