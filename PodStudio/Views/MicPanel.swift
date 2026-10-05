import StudioCore
import StudioServices
import SwiftUI

struct MicPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let capture = studio.capture
        ArcadeSection(title: "Mikrofon") {
            Menu {
                ForEach(capture.inputs) { input in
                    Button(input.name) { capture.selectInput(input.id) }
                }
            } label: {
                HStack {
                    Text(capture.inputs.first(where: { $0.id == capture.selectedInputID })?.name ?? "Eingang wählen")
                        .font(Arcade.chrome(14, weight: .bold))
                        .foregroundStyle(Arcade.ink)
                        .lineLimit(1)
                    Spacer()
                    Text("▼").font(Arcade.chrome(12)).foregroundStyle(Arcade.accent)
                }
                .padding(12)
                .background(Arcade.field)
                .overlay(Rectangle().strokeBorder(Arcade.line, lineWidth: 3))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .disabled(studio.isRecordingActive)

            VStack(alignment: .leading, spacing: 6) {
                SegmentMeter(meter: capture.meter, segments: 24)
                    .frame(height: 18)
                HStack {
                    Text("RMS \(dB(capture.meter.rmsDB))")
                    Spacer()
                    Text(capture.meter.clipped ? "CLIP!" : "Peak \(dB(capture.meter.peakHoldDB))")
                        .foregroundStyle(capture.meter.clipped ? Arcade.rec : Arcade.muted)
                }
                .font(Arcade.chrome(11))
                .foregroundStyle(Arcade.muted)
            }

            Toggle("Sprachverarbeitung (Echo-Unterdrückung)", isOn: Bindable(capture).voiceProcessingEnabled)
                .toggleStyle(.arcade)
                .disabled(studio.isRecordingActive)
            #if os(iOS)
            Toggle("AirPods in Studioqualität", isOn: Bindable(capture).bluetoothHighQualityRecording)
                .toggleStyle(.arcade)
                .disabled(studio.isRecordingActive)
            #endif

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("Mikrofonmodus", color: Arcade.muted)
                    Text(capture.microphoneModeName.isEmpty ? "–" : capture.microphoneModeName)
                        .font(Arcade.chrome(14, weight: .heavy)).foregroundStyle(Arcade.accent)
                }
                Spacer()
                Button("Ändern") { capture.showMicrophoneModes() }
                    .buttonStyle(.arcade(.ghost, compact: true))
                    .disabled(!capture.voiceProcessingEnabled)
            }
            if let error = capture.lastError {
                Text(error).font(Arcade.read(.caption)).foregroundStyle(Arcade.warn)
            }
            if !capture.isRunning {
                Button("Mikrofon starten") {
                    do { try capture.start() } catch { studio.errorMessage = error.localizedDescription }
                }
                .buttonStyle(.arcade)
            }
        }
        .onAppear { capture.refreshInputs() }
    }

    private func dB(_ v: Double) -> String { v > -100 ? String(format: "%.0f dB", v) : "-∞" }
}

/// Arcade LED meter: square segments, green → yellow → hot orange → red, peak-hold segment.
struct SegmentMeter: View {
    let meter: LevelMeter
    var segments: Int

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(segments - 1)) / CGFloat(segments))
            let lit = Int((LevelMeter.normalized(meter.rmsDB) * Double(segments)).rounded())
            let peak = Int((LevelMeter.normalized(meter.peakHoldDB) * Double(segments)).rounded()) - 1
            HStack(spacing: gap) {
                ForEach(0..<segments, id: \.self) { i in
                    Rectangle()
                        .fill(color(i).opacity(i < lit || i == peak ? 1 : 0.16))
                        .frame(width: w)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Pegel \(Int(meter.rmsDB)) dBFS")
    }

    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(segments)
        if f >= 0.95 { return Arcade.rec }        // > -3 dBFS
        if f >= 0.85 { return Arcade.accentHot }  // > -9 dBFS
        if f >= 0.65 { return Arcade.accent }     // > -21 dBFS
        return Arcade.ok
    }
}
