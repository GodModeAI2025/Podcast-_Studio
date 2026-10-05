import StudioCore
import StudioServices
import SwiftUI

struct MicPanel: View {
    @Environment(StudioController.self) private var studio
    #if os(iOS)
    @State private var picker = InputPickerHost()
    #endif

    var body: some View {
        let capture = studio.capture
        ArcadeSection(title: "Mikrofon") {
            inputSelector(capture)

            if !capture.isRunning {
                Text("Das Mikrofon ist gerade aus. Tippe unten auf „Mikrofon starten“.")
                    .font(Arcade.read(.footnote)).foregroundStyle(Arcade.warn)
            }
            VStack(alignment: .leading, spacing: 6) {
                SegmentMeter(meter: capture.meter, segments: 24)
                    .frame(height: 24)
                HStack {
                    Text("RMS \(dB(capture.meter.rmsDB))")
                    Spacer()
                    Text(capture.meter.clipped ? "Übersteuert" : "Peak \(dB(capture.meter.peakHoldDB))")
                        .foregroundStyle(capture.meter.clipped ? Arcade.rec : Arcade.muted)
                }
                .font(Arcade.chrome(13))
                .foregroundStyle(Arcade.muted)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Eingangspegel anheben").font(Arcade.read(.body)).foregroundStyle(Arcade.ink)
                    Spacer()
                    Text(capture.inputGainDB < 0.5 ? "aus" : "+\(Int(capture.inputGainDB)) dB")
                        .font(Arcade.chrome(17, weight: .bold)).foregroundStyle(Arcade.accent).monospacedDigit()
                }
                Slider(value: Bindable(capture).inputGainDB, in: 0...30, step: 1) { Text("Eingangspegel") }
                    .tint(Arcade.accent)
                    .disabled(studio.isRecordingActive)
                Text("Schlägt die Anzeige beim Sprechen kaum aus, heb den Pegel hier an. Gut sind Spitzen bei etwa -12 dB. Der Wert wirkt auf Anzeige und Aufnahme.")
                    .font(Arcade.read(.footnote)).foregroundStyle(Arcade.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
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
                                .font(Arcade.chrome(15, weight: .bold)).foregroundStyle(Arcade.accent)
                        }
                        Spacer()
                        Button("Ändern") { capture.showMicrophoneModes() }
                            .buttonStyle(.arcade(.ghost, compact: true))
                            .disabled(!capture.voiceProcessingEnabled)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Erweitert").font(Arcade.chrome(16, weight: .semibold)).foregroundStyle(Arcade.ink)
            }
            .tint(Arcade.accent)
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
        .onAppear {
            capture.ensureRunning()
            capture.refreshInputs()
        }
    }

    @ViewBuilder private func inputSelector(_ capture: AudioCaptureEngine) -> some View {
        #if os(iOS)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow("Aktives Mikrofon")
                Text(capture.activeInputName)
                    .font(Arcade.chrome(17, weight: .bold))
                    .foregroundStyle(Arcade.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button("Wechseln") { picker.present() }
                .buttonStyle(.arcade(.primary, compact: true))
                .disabled(studio.isRecordingActive)
        }
        .arcadeField()
        .background(InputPickerAnchor(host: picker))
        .onAppear {
            picker.onDismiss = { capture.refreshInputs() }
        }
        #else
        Menu {
            ForEach(capture.inputs) { input in
                Button(input.name) { capture.selectInput(input.id) }
            }
        } label: {
            HStack {
                Text(capture.inputs.first(where: { $0.id == capture.selectedInputID })?.name ?? "Eingang wählen")
                    .font(Arcade.chrome(16, weight: .bold))
                    .foregroundStyle(Arcade.ink)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.footnote.weight(.semibold)).foregroundStyle(Arcade.accent)
            }
            .arcadeField()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .disabled(studio.isRecordingActive)
        #endif
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
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
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
