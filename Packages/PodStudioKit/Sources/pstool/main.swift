import Foundation
import LAMEKit
import StudioCore

// pstool — post-production harness for acceptance checks without a device.
//
//   pstool loudness <file.wav>...                    integrated LUFS, sample/true peak
//   pstool render --out <dir> [--bitrate 128] [--wav] <a.wav> <b.wav>...
//                                                    voice chain + -16 LUFS per speaker,
//                                                    sum mix, MP3 per speaker + sum
//   pstool synth --out <dir> [--seconds 60]          synthetic speech-like test tracks at
//                                                    very different levels (Loop 4 check)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func fmt(_ v: Double) -> String {
    v.isFinite ? String(format: "%.2f", v) : "-inf"
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: pstool loudness|render|synth …")
}
args.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

switch command {
case "loudness":
    for path in args {
        do {
            let (format, channels) = try WAVReader.read(url: URL(fileURLWithPath: path))
            let lufs = Loudness.integrated(channels, sampleRate: Double(format.sampleRate))
            print("\(path): \(fmt(lufs)) LUFS, peak \(fmt(Loudness.samplePeakDB(channels))) dBFS, "
                  + "\(format.sampleRate) Hz, \(format.bitsPerSample) bit, \(format.channels) ch")
        } catch {
            fail("\(path): \(error)")
        }
    }

case "render":
    guard let out = option("--out") else { fail("--out <dir> required") }
    let bitrate = Int(option("--bitrate") ?? "128") ?? 128
    let alsoWAV = args.contains("--wav")
    args.removeAll { $0 == "--wav" }
    let outDir = URL(fileURLWithPath: out, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    var speakers: [SpeakerInput] = []
    var rate = 48_000
    for path in args {
        do {
            let (format, channels) = try WAVReader.read(url: URL(fileURLWithPath: path))
            guard format.sampleRate == 48_000 else { fail("\(path): expected 48 kHz (device pipeline resamples)") }
            rate = format.sampleRate
            // down-mix to mono
            let mono = channels.count == 1 ? channels[0] : (0..<channels[0].count).map { i in
                channels.reduce(Float(0)) { $0 + $1[i] } / Float(channels.count)
            }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            speakers.append(SpeakerInput(name: name, samples: mono))
        } catch {
            fail("\(path): \(error)")
        }
    }
    guard !speakers.isEmpty else { fail("no input files") }
    let sr = Double(rate)
    let maxLen = speakers.map(\.samples.count).max() ?? 0
    for i in speakers.indices {
        speakers[i].samples += [Float](repeating: 0, count: maxLen - speakers[i].samples.count)
    }
    let result = PostProductionPipeline.run(speakers: speakers, sampleRate: sr) { samples in
        VoiceChain.process(&samples, sampleRate: sr)
    }
    let settings = MP3Settings(bitrateKbps: bitrate, channelMode: .mono, sampleRate: rate)
    do {
        for s in result.speakers {
            let url = outDir.appendingPathComponent("\(s.name).mp3")
            try MP3Encoder.encodeFile(channels: [s.samples], to: url, settings: settings,
                                      tags: ID3Tags(title: s.name, album: "PodStudio"))
            if alsoWAV {
                try WAVWriter.write([s.samples], to: outDir.appendingPathComponent("\(s.name).wav"), format: .studio)
            }
            print("\(s.name): in \(fmt(s.report.inputLUFS)) LUFS → \(fmt(s.report.outputLUFS)) LUFS, "
                  + "gain \(fmt(s.report.appliedGainDB)) dB, peak \(fmt(s.report.outputPeakDB)) dBFS → \(url.path)")
        }
        let mixURL = outDir.appendingPathComponent("mix.mp3")
        try MP3Encoder.encodeFile(channels: [result.mix], to: mixURL, settings: settings,
                                  tags: ID3Tags(title: "Mix", album: "PodStudio"))
        print("mix: \(fmt(result.mixReport.outputLUFS)) LUFS, peak \(fmt(result.mixReport.outputPeakDB)) dBFS → \(mixURL.path)")
    } catch {
        fail("export failed: \(error)")
    }

case "synth":
    guard let out = option("--out") else { fail("--out <dir> required") }
    let seconds = Double(option("--seconds") ?? "60") ?? 60
    let outDir = URL(fileURLWithPath: out, isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let sr = 48_000.0
    let n = Int(seconds * sr)
    // Three "speakers": harmonic voice-like signal with syllable envelope, taking turns,
    // recorded at very different gains (-6, -20, -32 dB) plus some rumble and noise.
    let levels: [Double] = [-6, -20, -32]
    let pitches: [Double] = [110, 180, 140]
    var rng = SystemRandomNumberGenerator()
    for (k, level) in levels.enumerated() {
        var s = [Float](repeating: 0, count: n)
        let g = Decibel.toLinear(level)
        for i in 0..<n {
            let t = Double(i) / sr
            let turn = Int(t / 4) % levels.count == k  // 4 s turns
            let syllable = max(0, sin(2 * .pi * 3.3 * t))
            var v = 0.0
            for h in 1...8 { v += sin(2 * .pi * pitches[k] * Double(h) * t) / Double(h) }
            let voice = turn ? v * syllable * 0.35 : 0
            let rumble = 0.02 * sin(2 * .pi * 40 * t)
            let noise = Double.random(in: -1...1, using: &rng) * 0.0015
            s[i] = Float((voice + rumble) * g + noise)
        }
        let url = outDir.appendingPathComponent("speaker\(k + 1).wav")
        do {
            try WAVWriter.write([s], to: url, format: .studio)
        } catch {
            fail("\(url.path): \(error)")
        }
        print(url.path)
    }

default:
    fail("unknown command \(command)")
}
