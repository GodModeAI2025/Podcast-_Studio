import GroupActivities
import StudioCore
import StudioServices
import SwiftUI

/// Main studio screen: top bar with session + invite, self-view / mic / session / material
/// panels on one side, the script on the other, transport (REC) at the bottom.
struct StudioView: View {
    @Environment(StudioController.self) private var studio
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif
    @State private var camera = CameraController()
    @State private var panel: Panel = .script
    @State private var stepsDismissed = false

    enum Panel: String, CaseIterable, Identifiable {
        case script = "Drehbuch"
        case mic = "Mikro"
        case status = "Session"
        case delivery = "Material"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioTopBar()
            if isCompact { compactLayout } else { regularLayout }
            TransportBar()
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onDisappear { camera.stop() }
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
            Rectangle().fill(Arcade.line).frame(width: Arcade.edge)
            ScriptPanel()
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            NextStepsPanel(dismissed: $stepsDismissed)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            HStack(spacing: 8) {
                ForEach(Panel.allCases) { p in
                    Button(p.rawValue) { panel = p }
                        .buttonStyle(.arcade(panel == p ? .primary : .ghost, compact: true))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            Group {
                switch panel {
                case .script: ScriptPanel()
                case .mic: ScrollView { VStack(spacing: 20) { SelfView(camera: camera); MicPanel() }.padding(16) }
                case .status: ScrollView { SessionStatusPanel().padding(16) }
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

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Arcade.bar)
            Rectangle().fill(Arcade.barEdge).frame(height: 4)
            Rectangle().fill(Arcade.line).frame(height: 4)
        }
    }

    private var content: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(studio.isOwner ? "Host · Session" : "Gast · Session")
                Text(studio.current?.title ?? "")
                    .font(Arcade.chrome(18, weight: .heavy, relativeTo: .headline))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(Arcade.ink)
                    .lineLimit(1)
            }
            Spacer()
            liveBadge
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
    }

    @ViewBuilder private var liveBadge: some View {
        let live = studio.sharePlay.status == .joined
        HStack(spacing: 6) {
            Rectangle().fill(live ? Arcade.ok : Arcade.muted.opacity(0.5)).frame(width: 8, height: 8)
            Text(live ? "Live · \(studio.sharePlay.remoteParticipantCount + 1)" : "Offline")
                .font(Arcade.chrome(11, weight: .heavy))
                .textCase(.uppercase)
                .tracking(2)
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
                        Text("[ KAMERA AUS ]").font(Arcade.chrome(14, weight: .heavy))
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
                        .textCase(.uppercase)
                        .foregroundStyle(Arcade.ink)
                    Spacer()
                    SegmentMeter(meter: studio.capture.meter, segments: 12)
                        .frame(width: 90, height: 10)
                }
                .padding(10)
                .background(Arcade.bar.opacity(0.85))
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipped()
            .overlay(Rectangle().strokeBorder(Arcade.line, lineWidth: Arcade.edge))
            .modifier(HardShadow(offset: Arcade.dropLarge))

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
                        .textCase(.uppercase)
                        .foregroundStyle(Arcade.muted)
                }
            }
            if let e = camera.lastError {
                Text(e).font(Arcade.read(.caption)).foregroundStyle(Arcade.warn)
            }
        }
    }
}
