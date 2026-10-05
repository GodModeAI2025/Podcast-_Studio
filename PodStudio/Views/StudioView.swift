import GroupActivities
import StudioCore
import StudioServices
import SwiftUI

/// Main studio screen: video + mixer on one side, script on the other, transport below.
struct StudioView: View {
    @Environment(StudioController.self) private var studio
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var camera = CameraController()
    @State private var panel: Panel = .script

    enum Panel: String, CaseIterable, Identifiable {
        case script = "Drehbuch"
        case mic = "Mikrofon"
        case status = "Session"
        case delivery = "Material"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if sizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
            Divider()
            TransportBar()
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
        }
        .navigationTitle(studio.current?.title ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { InviteToolbar() }
        .onDisappear { camera.stop() }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VideoGrid(camera: camera)
                    MicPanel()
                    SessionStatusPanel()
                    DeliveryPanel()
                }
                .padding()
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 440)
            Divider()
            ScriptPanel()
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            VideoGrid(camera: camera)
                .frame(height: 180)
                .padding(.horizontal)
                .padding(.top, 8)
            Picker("Bereich", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()
            Group {
                switch panel {
                case .script: ScriptPanel()
                case .mic: ScrollView { MicPanel().padding() }
                case .status: ScrollView { SessionStatusPanel().padding() }
                case .delivery: ScrollView { DeliveryPanel().padding() }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// SharePlay invitation: `ShareLink` with the GroupActivity works without a running
/// FaceTime call (Messages link, TN3128). During a call, "Activate" starts it directly.
struct InviteToolbar: ToolbarContent {
    @Environment(StudioController.self) private var studio

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let session = studio.current, session.isOwner {
                let activity = studio.activity(for: session)
                if studio.sharePlay.isEligibleForGroupSession && !studio.isInSharePlay {
                    Button {
                        Task { _ = await studio.sharePlay.activate(activity) }
                    } label: {
                        Label("SharePlay starten", systemImage: "shareplay")
                    }
                }
                ShareLink(item: activity, preview: SharePreview("PodStudio: \(session.title)")) {
                    Label("Gäste einladen", systemImage: "person.badge.plus")
                }
            }
            if studio.isInSharePlay {
                Button(role: .destructive) { studio.sharePlay.leave() } label: {
                    Label("Session verlassen", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }
}

struct VideoGrid: View {
    @Environment(StudioController.self) private var studio
    let camera: CameraController
    @State private var showCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.85))
                if showCamera && camera.isRunning {
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.title)
                        Text("Kamera aus").font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(studio.identity.displayName)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        LevelMeterView(meter: studio.capture.meter, compact: true)
                            .frame(width: 60, height: 6)
                    }
                    .padding(8)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            HStack {
                Toggle(isOn: $showCamera) { Label("Kamera", systemImage: "video") }
                    .toggleStyle(.button)
                    .onChange(of: showCamera) { _, on in
                        if on { Task { await camera.start() } } else { camera.stop() }
                    }
                Spacer()
                if studio.isInSharePlay {
                    Label("\(studio.sharePlay.remoteParticipantCount) Gäste live über FaceTime",
                          systemImage: "person.2.wave.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let e = camera.lastError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
