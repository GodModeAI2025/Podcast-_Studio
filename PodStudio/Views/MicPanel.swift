import StudioCore
import StudioServices
import SwiftUI

struct MicPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        let capture = studio.capture
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Eingang", selection: Binding(get: { capture.selectedInputID ?? "" },
                                                     set: { capture.selectInput($0) })) {
                    ForEach(capture.inputs) { input in
                        Label(input.name, systemImage: input.isBluetooth ? "airpods" : input.isBuiltIn ? "mic" : "cable.connector")
                            .tag(input.id)
                    }
                }
                .disabled(studio.isRecordingActive)

                LevelMeterView(meter: capture.meter, compact: false)
                    .frame(height: 14)

                Toggle("Sprachverarbeitung (Echo-Unterdrückung)", isOn: Bindable(capture).voiceProcessingEnabled)
                    .disabled(studio.isRecordingActive)
                #if os(iOS)
                Toggle("AirPods in Studioqualität", isOn: Bindable(capture).bluetoothHighQualityRecording)
                    .disabled(studio.isRecordingActive)
                #endif

                HStack {
                    Text("Mikrofonmodus: \(capture.microphoneModeName)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Ändern …") { capture.showMicrophoneModes() }
                        .disabled(!capture.voiceProcessingEnabled)
                }
                if let error = capture.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if !capture.isRunning {
                    Button("Mikrofon starten") {
                        do { try capture.start() } catch { studio.errorMessage = error.localizedDescription }
                    }
                }
            }
        } label: {
            Label("Mikrofon", systemImage: "mic")
        }
        .onAppear { capture.refreshInputs() }
    }
}

struct LevelMeterView: View {
    let meter: LevelMeter
    var compact: Bool

    var body: some View {
        GeometryReader { geo in
            let rms = LevelMeter.normalized(meter.rmsDB)
            let peak = LevelMeter.normalized(meter.peakHoldDB)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * rms)
                    }
                Rectangle()
                    .fill(meter.clipped ? Color.red : Color.primary)
                    .frame(width: 2)
                    .offset(x: max(0, geo.size.width * peak - 2))
            }
        }
        .accessibilityLabel("Pegel \(Int(meter.rmsDB)) dBFS")
        .overlay(alignment: .trailing) {
            if !compact {
                Text(meter.peakHoldDB > -100 ? String(format: "%.0f dB", meter.peakHoldDB) : "–∞")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(meter.clipped ? .red : .secondary)
                    .offset(x: 44)
            }
        }
        .padding(.trailing, compact ? 0 : 44)
    }
}
