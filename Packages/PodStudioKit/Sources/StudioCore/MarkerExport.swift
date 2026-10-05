import Foundation

/// Maps markers (shared clock) onto the exported timeline (pauses removed) and writes
/// them as Audacity label track and as a simple chapter list.
public enum MarkerExport {
    /// Position of a shared-clock time on the output timeline in seconds, or `nil` if it
    /// falls into a pause / outside the recording.
    public static func timelinePosition(of time: TimeInterval, windows: [RecordingWindow]) -> TimeInterval? {
        var offset: TimeInterval = 0
        for w in windows.sorted(by: { $0.index < $1.index }) {
            let end = w.end ?? .infinity
            if time >= w.start && time <= end { return offset + (time - w.start) }
            guard let e = w.end else { return nil }
            offset += e - w.start
        }
        return nil
    }

    public struct Entry: Sendable, Equatable {
        public var position: TimeInterval
        public var note: String
    }

    public static func entries(_ markers: [Marker], windows: [RecordingWindow]) -> [Entry] {
        markers.compactMap { m in
            timelinePosition(of: m.at, windows: windows).map { Entry(position: $0, note: m.note) }
        }
        .sorted { $0.position < $1.position }
    }

    /// Audacity label format: `start<TAB>end<TAB>label`
    public static func audacityLabels(_ markers: [Marker], windows: [RecordingWindow]) -> String {
        entries(markers, windows: windows).enumerated().map { i, e in
            let t = String(format: "%.6f", e.position)
            return "\(t)\t\(t)\t\(e.note.isEmpty ? "Marker \(i + 1)" : e.note)"
        }
        .joined(separator: "\n") + "\n"
    }

    /// `HH:MM:SS Notiz` per line (podcast chapter style).
    public static func chapterList(_ markers: [Marker], windows: [RecordingWindow]) -> String {
        entries(markers, windows: windows).enumerated().map { i, e in
            let s = Int(e.position)
            let stamp = String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            return "\(stamp) \(e.note.isEmpty ? "Marker \(i + 1)" : e.note)"
        }
        .joined(separator: "\n") + "\n"
    }
}
