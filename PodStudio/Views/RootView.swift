import LAMEKit
import StudioCore
import StudioServices
import SwiftUI

struct RootView: View {
    @Environment(StudioController.self) private var studio
    @State private var showNewSession = false
    @State private var newTitle = ""
    @State private var showRecovery = false
    @State private var column: NavigationSplitViewColumn = .sidebar

    var body: some View {
        @Bindable var studio = studio
        content(studio: studio)
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

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    @ViewBuilder private func content(studio: StudioController) -> some View {
        if isPhone {
            phoneBody(studio: studio)
        } else {
            splitBody(studio: studio)
        }
    }

    /// iPhone: session list → pushed studio screen (works in portrait and landscape).
    private func phoneBody(studio: StudioController) -> some View {
        NavigationStack {
            SessionListView(showNewSession: $showNewSession)
                .navigationDestination(isPresented: Binding(
                    get: { studio.current != nil },
                    set: { if !$0 { studio.close() } })) {
                    ZStack {
                        ArcadeBackground()
                        StudioView(onBack: { studio.close() })
                    }
                }
        }
    }

    private func splitBody(studio: StudioController) -> some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            SessionListView(showNewSession: $showNewSession)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
                #endif
        } detail: {
            ZStack {
                ArcadeBackground()
                if studio.current != nil {
                    StudioView(onBack: { column = .sidebar })
                } else {
                    WelcomeView(showNewSession: $showNewSession)
                }
            }
        }
        .onChange(of: studio.current?.id) { _, id in
            // iPhone: jump from the list to the opened session.
            if id != nil { column = .detail }
        }
    }
}

/// Landing ("Hero") when no session is open.
private struct WelcomeView: View {
    @Binding var showNewSession: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Eyebrow("Podcast-Studio · iPhone + Mac")
                Text("Aufnehmen wie im Studio.\nVerbunden über SharePlay.")
                    .arcadeHeadline(40, shadow: 5)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Jedes Gerät nimmt lokal in 48 kHz / 24 Bit auf. Das Netz trägt nur Gespräch, Drehbuch und Startsignal. Am Ende landen alle Spuren bei dir: eine MP3 je Stimme und die Summe, fertig auf -16 LUFS.")
                    .font(Arcade.read(.title3))
                    .foregroundStyle(Arcade.ink)
                    .frame(maxWidth: 560, alignment: .leading)
                HStack(spacing: 14) {
                    Button("Neue Session") { showNewSession = true }
                        .buttonStyle(.arcade)
                }
                HStack(spacing: 18) {
                    feature("01", "Einladen", "Link über Nachrichten oder FaceTime. Kein Konto, kein Server.")
                    feature("02", "Aufnehmen", "REC startet auf allen Geräten am selben Sample.")
                    feature("03", "Abholen", "Spuren kommen per iCloud. Mischen, MP3, fertig.")
                }
            }
            .padding(40)
            .frame(maxWidth: 1000, alignment: .leading)
        }
    }

    private func feature(_ n: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(n).font(Arcade.chrome(13)).foregroundStyle(Arcade.line)
            Text(title).arcadeHeadline(17, shadow: 2)
            Text(text).font(Arcade.read(.callout)).foregroundStyle(Arcade.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .arcadePanel()
    }
}

struct SessionListView: View {
    @Environment(StudioController.self) private var studio
    @Binding var showNewSession: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("PodStudio").arcadeHeadline(20, shadow: 2)
                    Spacer()
                    Button { showNewSession = true } label: { Text("+ Neu") }
                        .buttonStyle(.arcade(.primary, compact: true))
                        .keyboardShortcut("n", modifiers: .command)
                }
                .padding(.bottom, 22)

                Eyebrow("Sessions · \(studio.sessions.count)")
                    .padding(.bottom, 8)
                Rectangle().fill(Arcade.hairline).frame(height: 1)

                ForEach(studio.sessions) { session in
                    row(session)
                }
                if studio.sessions.isEmpty {
                    Text("Noch keine Session.")
                        .font(Arcade.read(.callout))
                        .foregroundStyle(Arcade.muted)
                        .padding(.vertical, 14)
                }
            }
            .padding(18)
        }
        .background(Arcade.bar)
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { SettingsView() } label: { Label("Einstellungen", systemImage: "gearshape") }
            }
            #endif
        }
    }

    private func row(_ session: SessionManifest) -> some View {
        let selected = studio.current?.id == session.id
        return Button {
            studio.open(session)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(session.isOwner ? "HOST" : "GAST")
                    .font(Arcade.chrome(10, weight: .heavy))
                    .foregroundStyle(session.isOwner ? Arcade.accentInk : Arcade.ink)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(session.isOwner ? Arcade.accent : Arcade.panelStrong)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(Arcade.read(.body).weight(.semibold))
                        .foregroundStyle(selected ? Arcade.accent : Arcade.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text(session.createdAt, format: .dateTime.day().month().year())
                        Text(stateLabel(session.state))
                    }
                    .font(Arcade.chrome(11))
                    .foregroundStyle(session.state == .recording ? Arcade.rec : Arcade.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? Arcade.panelStrong : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Löschen", role: .destructive) { studio.delete(session) }
        }
    }

    private func stateLabel(_ s: RecordingState) -> String {
        switch s {
        case .idle: return "bereit"
        case .recording: return "● rec"
        case .paused: return "pause"
        case .finished: return "fertig"
        case .recovered: return "gerettet"
        }
    }
}

struct SettingsView: View {
    @Environment(StudioController.self) private var studio
    @State private var name = ""

    var body: some View {
        @Bindable var studio = studio
        ZStack {
            ArcadeBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Einstellungen").arcadeHeadline(26)

                    ArcadeSection(title: "Profil") {
                        TextField("Anzeigename", text: $name)
                            .textFieldStyle(.plain)
                            .font(Arcade.chrome(16))
                            .foregroundStyle(Arcade.ink)
                            .arcadeField()
                            .onSubmit { studio.rename(name) }
                        Text("So sehen dich die anderen in der Session und in den Dateinamen.")
                            .font(Arcade.read(.caption)).foregroundStyle(Arcade.muted)
                    }

                    ArcadeSection(title: "Export") {
                        ChoiceRow(title: "MP3-Bitrate", options: [128, 160, 192].map { ("\($0) kbps", $0) },
                                  selection: $studio.exportOptions.mp3.bitrateKbps)
                        ChoiceRow(title: "Kanäle", options: [("Mono", MP3Settings.ChannelMode.mono), ("Stereo", .stereo)],
                                  selection: $studio.exportOptions.mp3.channelMode)
                        Toggle("Zusätzlich AAC (M4A)", isOn: $studio.exportOptions.alsoAAC).toggleStyle(.arcade)
                        Toggle("Zusätzlich WAV (24 Bit)", isOn: $studio.exportOptions.alsoWAV).toggleStyle(.arcade)
                        LoudnessSlider()
                    }

                    ArcadeSection(title: "iCloud") {
                        HStack {
                            Text("Account").font(Arcade.read()).foregroundStyle(Arcade.ink)
                            Spacer()
                            Text(accountLabel).font(Arcade.chrome(13))
                                .foregroundStyle(studio.delivery.accountStatus == .available ? Arcade.ok : Arcade.warn)
                        }
                    }
                }
                .padding(28)
            }
        }
        .navigationTitle("Einstellungen")
        .onAppear { name = studio.identity.displayName }
        .onDisappear { if !name.isEmpty { studio.rename(name) } }
    }

    private var accountLabel: String {
        switch studio.delivery.accountStatus {
        case .available: return "verfügbar"
        case .noAccount: return "nicht angemeldet"
        case .restricted: return "eingeschränkt"
        case .temporarilyUnavailable: return "vorübergehend weg"
        default: return "unbekannt"
        }
    }
}

/// Export loudness as a slider (LUFS), with an explanation.
struct LoudnessSlider: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        @Bindable var studio = studio
        let value = studio.exportOptions.loudness.integratedLUFS
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lautstärke beim Export").font(Arcade.read(.body)).foregroundStyle(Arcade.ink)
                Spacer()
                Text("\(Int(value)) LUFS").font(Arcade.chrome(17, weight: .bold)).foregroundStyle(Arcade.accent)
                    .monospacedDigit()
            }
            Slider(value: $studio.exportOptions.loudness.integratedLUFS, in: -24...(-12), step: 1) {
                Text("Lautstärke")
            } minimumValueLabel: {
                Text("leiser").font(Arcade.read(.caption)).foregroundStyle(Arcade.muted)
            } maximumValueLabel: {
                Text("lauter").font(Arcade.read(.caption)).foregroundStyle(Arcade.muted)
            }
            .tint(Arcade.accent)
            Text(hint(value))
                .font(Arcade.read(.footnote)).foregroundStyle(Arcade.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func hint(_ v: Double) -> String {
        let base = "Alle Stimmen und die Summe werden beim Export auf diese durchschnittliche Lautstärke gebracht, damit niemand lauter oder leiser klingt."
        switch Int(v) {
        case -16: return base + " -16 ist der Standard für Podcasts (Apple Podcasts, Spotify)."
        case -14: return base + " -14 ist die Lautstärke von Musik-Streaming, etwas lauter als üblich."
        case -23: return base + " -23 entspricht der Rundfunknorm EBU R128."
        default: return base + " Empfehlung: -16."
        }
    }
}

/// Segmented choice as a row of arcade buttons.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title, color: Arcade.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10, alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                ForEach(options.indices, id: \.self) { i in
                    let option = options[i]
                    Button(option.0) { selection = option.1 }
                        .buttonStyle(.arcade(selection == option.1 ? .primary : .ghost, compact: true))
                }
            }
        }
    }
}
