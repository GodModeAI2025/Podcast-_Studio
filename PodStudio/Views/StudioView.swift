import GroupActivities
import StudioCore
import StudioServices
import SwiftUI

/// Main studio screen: top bar with session + invite, self-view / mic / session / material
/// panels on one side, the script on the other, transport (REC) at the bottom.
struct StudioView: View {
    @Environment(StudioController.self) private var studio
    var onBack: () -> Void = {}
    #if os(iOS)
    /// iPhones always use the one-screen-at-a-time layout, also in landscape.
    private var isCompact: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    #else
    private var isCompact: Bool { false }
    #endif
    @State private var camera = CameraController()
    @State private var panel: Panel = .start
    @State private var stepsDismissed = false
    @State private var showSettings = false

    enum Panel: String, CaseIterable, Identifiable {
        case start = "Start"
        case script = "Drehbuch"
        case mic = "Mikro"
        case status = "Session"
        case delivery = "Material"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioTopBar(onBack: isCompact ? onBack : nil, onSettings: { showSettings = true })
            if isCompact { compactLayout } else { regularLayout }
            TransportBar()
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onDisappear { camera.stop() }
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showSettings = false } }
                    }
            }
            .environment(studio)
            .preferredColorScheme(.dark)
            .tint(Arcade.accent)
        }
        #endif
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    NextStepsPanel(dismissed: $stepsDismissed)
                    SelfView(camera: camera)
                    MicPanel()
                    SessionStatusPanel()
                    DeliveryPanel()
                }
                .padding(22)
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
            Rectangle().fill(Arcade.hairline).frame(width: 1)
            ScriptPanel()
        }
    }

    private var showStart: Bool { NextStepsPanel.shouldShow(studio, dismissed: stepsDismissed) }

    private var compactLayout: some View {
        let current: Panel = (panel == .start && !showStart) ? .script : panel
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Panel.allCases.filter { $0 != .start || showStart }) { p in
                        Button(p.rawValue) { panel = p }
                            .buttonStyle(.arcade(current == p ? .primary : .ghost, compact: true))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Group {
                switch current {
                case .start: ScrollView { NextStepsPanel(dismissed: $stepsDismissed).padding(16) }
                case .script: ScriptPanel()
                case .mic: ScrollView { MicPanel().padding(16) }
                case .status: ScrollView { VStack(spacing: 20) { SessionStatusPanel(); SelfView(camera: camera) }.padding(16) }
                case .delivery: ScrollView { DeliveryPanel().padding(16) }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// `.lp-top`: sticky bar with mark, session title and the call to action (invite).
struct StudioTopBar: View {
    @Environment(StudioController.self) private var studio
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Arcade.bar)
            Rectangle().fill(Arcade.hairline).frame(height: 1)
        }
    }

    @ViewBuilder private var content: some View {
        if onBack != nil {
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                HStack(spacing: 10) { actions }
            }
        } else {
            HStack(spacing: 16) {
                titleRow
                actions
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: 14) {
            if let onBack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.arcade(.ghost, compact: true))
                    .accessibilityLabel("Zur Sessionliste")
            }
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(studio.isOwner ? "Host" : "Gast")
                Text(studio.current?.title ?? "")
                    .font(Arcade.chrome(20, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Arcade.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            liveBadge
            #if os(iOS)
            if let onSettings {
                Button { onSettings() } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.arcade(.ghost, compact: true))
                    .accessibilityLabel("Einstellungen")
            }
            #endif
        }
    }

    @ViewBuilder private var actions: some View {
        if let session = studio.current, session.isOwner {
            let activity = studio.activity(for: session)
            if studio.sharePlay.isEligibleForGroupSession && !studio.isInSharePlay {
                Button("SharePlay") { Task { _ = await studio.sharePlay.activate(activity) } }
                    .buttonStyle(.arcade(.ghost, compact: true))
            }
            ShareLink(item: activity, preview: SharePreview("PodStudio: \(session.title)")) {
                Text("Gäste einladen")
            }
            .buttonStyle(.arcade(.primary, compact: true))
        }
        if studio.isInSharePlay {
            Button("Verlassen") { studio.sharePlay.leave() }
                .buttonStyle(.arcade(.ghost, compact: true))
        }
    }

    @ViewBuilder private var liveBadge: some View {
        let live = studio.sharePlay.status == .joined
        HStack(spacing: 6) {
            Circle().fill(live ? Arcade.ok : Arcade.muted.opacity(0.5)).frame(width: 9, height: 9)
            Text(live ? "Live · \(studio.sharePlay.remoteParticipantCount + 1)" : "Offline")
                .font(Arcade.chrome(11, weight: .heavy))
                .foregroundStyle(live ? Arcade.ok : Arcade.muted)
        }
    }
}

/// Local camera = self-view only. Video is never recorded; the session produces audio.
struct SelfView: View {
    @Environment(StudioController.self) private var studio
    let camera: CameraController
    @State private var showCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Arcade.bgDeep)
                if showCamera && camera.isRunning {
                    CameraPreview(session: camera.session)
                } else {
                    VStack(spacing: 8) {
                        Text("Kamera aus").font(Arcade.chrome(14, weight: .heavy))
                        Text("Nur Vorschau · es wird nur Audio aufgenommen")
                            .font(Arcade.read(.caption))
                    }
                    .foregroundStyle(Arcade.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 10) {
                    Monogram(name: studio.identity.displayName)
                    Text(studio.identity.displayName)
                        .font(Arcade.chrome(12, weight: .heavy))
                        .foregroundStyle(Arcade.ink)
                    Spacer()
                    SegmentMeter(meter: studio.capture.meter, segments: 12)
                        .frame(width: 90, height: 10)
                }
                .padding(10)
                .background(Arcade.bar.opacity(0.85))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Arcade.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Arcade.radius, style: .continuous).strokeBorder(Arcade.hairline, lineWidth: 1))

            HStack {
                Toggle("Selbstansicht", isOn: $showCamera)
                    .toggleStyle(.arcade)
                    .fixedSize()
                    .onChange(of: showCamera) { _, on in
                        if on { Task { await camera.start() } } else { camera.stop() }
                    }
                Spacer()
                if studio.isInSharePlay {
                    Text("Gäste sehen & hören: FaceTime")
                        .font(Arcade.chrome(11))
                        .foregroundStyle(Arcade.muted)
                }
            }
            if let e = camera.lastError {
                Text(e).font(Arcade.read(.caption)).foregroundStyle(Arcade.warn)
            }
        }
    }
}
