import StudioCore
import StudioServices
import SwiftUI

/// Live fact check (Private Cloud Compute + web research) and script coverage.
struct FactsPanel: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        VStack(spacing: 20) {
            controlCard
            CoverageCard()
            cardsSection
            ideasSection
            transcriptSection
        }
    }

    // MARK: Control

    private var controlCard: some View {
        @Bindable var studio = studio
        return ArcadeSection(title: "Faktencheck live", accent: studio.factCheckEnabled ? Arcade.ok : nil) {
            Toggle("Mithören und Fakten prüfen", isOn: $studio.factCheckEnabled)
                .toggleStyle(.arcade)
            Text("Dein Mikrofon wird auf dem Gerät in Text umgewandelt. Nur kurze Textausschnitte gehen zur Prüfung an Apples Private Cloud Compute. Zur Recherche fragt sie außerdem Wikipedia und DuckDuckGo mit kurzen Suchbegriffen ab. Audio verlässt das Gerät dafür nicht. Nur der Host prüft, die anderen schicken ihre Sätze an ihn. Du kannst das jederzeit ausschalten.")
                .font(Arcade.read(.footnote)).foregroundStyle(Arcade.muted)
                .fixedSize(horizontal: false, vertical: true)
            if studio.factCheckEnabled {
                statusRows
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusLine(icon: "waveform", title: "Spracherkennung", value: transcriberText, color: transcriberColor)
            if studio.isOwner {
                statusLine(icon: "checkmark.shield", title: "Prüfung", value: factsText, color: factsColor)
                if let error = studio.facts.lastError {
                    Text(error).font(Arcade.read(.footnote)).foregroundStyle(Arcade.warn)
                }
                Button("Jetzt prüfen") { studio.facts.checkNow(topic: studio.current?.title ?? "") }
                    .buttonStyle(.arcade(.ghost, compact: true))
                    .disabled(studio.transcript.isEmpty)
            } else {
                statusLine(icon: "person.2", title: "Prüfung", value: "läuft beim Host", color: Arcade.muted)
            }
        }
    }

    private func statusLine(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Text(title).font(Arcade.read(.body)).foregroundStyle(Arcade.ink)
            Spacer(minLength: 8)
            Text(value).font(Arcade.chrome(14, weight: .semibold)).foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private var transcriberText: String {
        switch studio.transcriber.state {
        case .off: return studio.isRecordingActive ? "startet …" : "startet mit REC"
        case .preparing(let s): return s
        case .listening: return studio.transcriber.partial.isEmpty ? "hört zu" : "hört zu …"
        case .unavailable(let s): return s
        }
    }

    private var transcriberColor: Color {
        switch studio.transcriber.state {
        case .listening: return Arcade.ok
        case .unavailable: return Arcade.warn
        default: return Arcade.muted
        }
    }

    private var factsText: String {
        switch studio.facts.status {
        case .off: return "aus"
        case .idle: return studio.facts.cards.isEmpty ? "wartet auf Text" : "bereit"
        case .checking: return "prüft gerade …"
        case .unavailable(let s), .paused(let s): return s
        }
    }

    private var factsColor: Color {
        switch studio.facts.status {
        case .idle: return Arcade.ok
        case .checking: return Arcade.accent
        case .unavailable, .paused: return Arcade.warn
        case .off: return Arcade.muted
        }
    }

    // MARK: Results

    @ViewBuilder private var cardsSection: some View {
        if studio.isOwner, studio.factCheckEnabled {
            ArcadeSection(title: "Geprüft") {
                if studio.facts.cards.isEmpty {
                    Text("Sobald genug gesprochen wurde, erscheinen hier die geprüften Aussagen mit Hinweis, ob sie stimmen.")
                        .font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                } else {
                    ForEach(studio.facts.cards) { card in FactCardView(card: card) }
                }
            }
        }
    }

    @ViewBuilder private var ideasSection: some View {
        if studio.isOwner, studio.factCheckEnabled, !studio.facts.ideas.isEmpty {
            ArcadeSection(title: "Weitere Fakten zum Erwähnen", accent: Arcade.accent) {
                ForEach(studio.facts.ideas) { idea in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(idea.title).font(Arcade.read(.headline)).foregroundStyle(Arcade.ink)
                        Text(idea.detail).font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if let url = idea.sourceURL {
                            Link(destination: url) { Label("Quelle", systemImage: "link") }
                                .font(Arcade.read(.footnote)).tint(Arcade.line)
                        }
                    }
                    if idea.id != studio.facts.ideas.last?.id {
                        Rectangle().fill(Arcade.hairline).frame(height: 1)
                    }
                }
            }
        }
    }

    @ViewBuilder private var transcriptSection: some View {
        if studio.factCheckEnabled {
            ArcadeSection(title: "Mitgeschrieben") {
                if studio.transcript.isEmpty && studio.transcriber.partial.isEmpty {
                    Text("Noch nichts gesprochen.").font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                }
                ForEach(studio.transcript.suffix(8)) { line in
                    (Text(line.speakerName + ": ").font(Arcade.read(.callout).weight(.semibold)).foregroundStyle(Arcade.accent)
                        + Text(line.text).font(Arcade.read(.callout)).foregroundStyle(Arcade.ink))
                }
                if !studio.transcriber.partial.isEmpty {
                    Text(studio.transcriber.partial).font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                }
            }
        }
    }
}

private struct FactCardView: View {
    let card: FactCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(Arcade.chrome(12, weight: .heavy))
                    .foregroundStyle(Arcade.accentInk)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(color))
                Text(timecode(card.at)).font(Arcade.chrome(12)).foregroundStyle(Arcade.muted)
            }
            Text(card.claim).font(Arcade.read(.body).weight(.semibold)).foregroundStyle(Arcade.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.note).font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let url = card.sourceURL {
                Link(destination: url) { Label(card.sourceTitle ?? "Quelle", systemImage: "link") }
                    .font(Arcade.read(.footnote)).tint(Arcade.line)
            }
        }
        .padding(.bottom, 6)
    }

    private var label: String {
        switch card.verdict {
        case .confirmed: return "Stimmt"
        case .uncertain: return "Unklar"
        case .doubtful: return "Zweifelhaft"
        }
    }

    private var color: Color {
        switch card.verdict {
        case .confirmed: return Arcade.ok
        case .uncertain: return Arcade.warn
        case .doubtful: return Arcade.rec
        }
    }

    private func timecode(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Script topics the conversation has not touched yet, shown while the episode is < 45 min.
struct CoverageCard: View {
    @Environment(StudioController.self) private var studio

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let report = studio.coverage
            ArcadeSection(title: "Drehbuch im Blick", accent: report.forgotten.isEmpty ? nil : Arcade.warn) {
                if !studio.factCheckEnabled {
                    Text("Schalte „Mithören und Fakten prüfen“ ein. Dann erkennt PodStudio, welche Themen aus dem Drehbuch schon besprochen wurden, und weist auf vergessene hin.")
                        .font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                } else if !report.showsHints {
                    Text("Die Folge läuft schon über 45 Minuten. Hinweise auf vergessene Themen werden jetzt nicht mehr angezeigt.")
                        .font(Arcade.read(.callout)).foregroundStyle(Arcade.muted)
                } else {
                    content(report)
                }
            }
        }
    }

    @ViewBuilder private func content(_ report: TopicCoverage.Report) -> some View {
        if report.forgotten.isEmpty {
            Label("Nichts vergessen, alles bisher Besprochene passt zum Drehbuch.", systemImage: "checkmark.circle")
                .font(Arcade.read(.callout)).foregroundStyle(Arcade.ok)
        } else {
            Text("Vergessen? Dazu fehlt noch etwas, obwohl ihr schon weiter seid:")
                .font(Arcade.read(.callout)).foregroundStyle(Arcade.warn)
            ForEach(report.forgotten) { entry in topicRow(entry, color: Arcade.warn) }
        }
        let upcoming = report.open.filter { $0.status == .open && !report.forgotten.contains($0) }
        if !upcoming.isEmpty {
            Rectangle().fill(Arcade.hairline).frame(height: 1)
            Eyebrow("Noch offen")
            ForEach(upcoming) { entry in topicRow(entry, color: Arcade.muted) }
        }
    }

    private func topicRow(_ entry: TopicCoverage.Entry, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title.isEmpty ? "Einstieg" : entry.title)
                .font(Arcade.read(.body).weight(.semibold)).foregroundStyle(Arcade.ink)
            if !entry.missing.isEmpty {
                Text("Fehlt: " + entry.missing.prefix(5).joined(separator: ", "))
                    .font(Arcade.read(.footnote)).foregroundStyle(color)
            }
        }
    }
}
