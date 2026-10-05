#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Observation
import StudioCore

// MARK: - Structured output of the model

@Generable
enum ClaimVerdict: String {
    case confirmed
    case uncertain
    case doubtful
}

@Generable
struct ClaimCheck {
    @Guide(description: "Die geprüfte Behauptung aus dem Gespräch, in einem kurzen Satz")
    var claim: String
    @Guide(description: "confirmed = durch die Recherche bestätigt, uncertain = nicht eindeutig belegbar, doubtful = widerspricht der Recherche")
    var verdict: ClaimVerdict
    @Guide(description: "Kurze Begründung auf Deutsch, höchstens zwei Sätze")
    var note: String
    @Guide(description: "Titel der Quelle, zum Beispiel der Wikipedia-Artikel")
    var sourceTitle: String?
    @Guide(description: "Vollständige URL der Quelle aus den Suchergebnissen, sonst leer lassen")
    var sourceURL: String?
}

@Generable
struct IdeaSuggestion {
    @Guide(description: "Kurzer Titel eines weiteren interessanten Fakts zum Thema")
    var title: String
    @Guide(description: "Ein bis zwei Sätze auf Deutsch, die der Moderator erwähnen könnte")
    var detail: String
    @Guide(description: "URL der Quelle aus den Suchergebnissen, sonst leer lassen")
    var sourceURL: String?
}

@Generable
struct FactCheckReport {
    @Guide(description: "Höchstens vier überprüfbare Tatsachenbehauptungen aus dem Textausschnitt. Meinungen und Floskeln auslassen.")
    var claims: [ClaimCheck]
    @Guide(description: "Höchstens drei weitere interessante, belegte Fakten zum Thema, die im Gespräch noch nicht vorkamen")
    var ideas: [IdeaSuggestion]
}

// MARK: - Research tools (the model decides when to call them)

struct WikipediaSearchTool: Tool {
    let name = "wikipedia_suche"
    let description = "Sucht in der deutschsprachigen Wikipedia und liefert Titel, Kurztext und URL der besten Treffer. Zum Prüfen von Fakten verwenden."

    @Generable
    struct Arguments {
        @Guide(description: "Suchbegriff oder kurze Frage, zum Beispiel 'Höhe Zugspitze'")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        var components = URLComponents(string: "https://de.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: arguments.query),
            .init(name: "gsrlimit", value: "3"), .init(name: "prop", value: "extracts|info"),
            .init(name: "exintro", value: "1"), .init(name: "explaintext", value: "1"),
            .init(name: "exchars", value: "700"), .init(name: "exlimit", value: "3"),
            .init(name: "inprop", value: "url"), .init(name: "redirects", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue("PodStudio/1.0 (Faktencheck)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [String: [String: Any]], !pages.isEmpty else {
            return "Keine Treffer in der Wikipedia."
        }
        let sorted = pages.values.sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
        return sorted.map { page in
            let title = page["title"] as? String ?? "?"
            let extract = (page["extract"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            let url = page["fullurl"] as? String ?? ""
            return "Titel: \(title)\nURL: \(url)\nText: \(extract)"
        }.joined(separator: "\n\n")
    }
}

struct WebAnswerTool: Tool {
    let name = "web_kurzantwort"
    let description = "Fragt eine allgemeine Websuche (DuckDuckGo) nach einer Kurzantwort zu einem Begriff. Ergänzend zur Wikipedia verwenden."

    @Generable
    struct Arguments {
        @Guide(description: "Suchbegriff")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            .init(name: "q", value: arguments.query), .init(name: "format", value: "json"),
            .init(name: "no_html", value: "1"), .init(name: "skip_disambig", value: "1"),
            .init(name: "no_redirect", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Keine Antwort." }
        let abstract = root["AbstractText"] as? String ?? ""
        let source = root["AbstractSource"] as? String ?? ""
        let url = root["AbstractURL"] as? String ?? ""
        if abstract.isEmpty { return "Keine Kurzantwort gefunden." }
        return "Quelle: \(source)\nURL: \(url)\nText: \(abstract)"
    }
}

// MARK: - Service

/// Checks what was said against research results using Apple's Private Cloud Compute model.
/// Only text snippets of the transcript leave the device (to PCC and to the research
/// tools), never audio. Opt-in, off by default.
@MainActor
@Observable
public final class FactCheckService {
    public enum Status: Equatable {
        case off
        case idle
        case checking
        case unavailable(String)
        case paused(String)
    }

    public private(set) var status: Status = .off
    public private(set) var cards: [FactCard] = []
    public private(set) var ideas: [IdeaCard] = []
    public private(set) var lastError: String?

    private var pending: [TranscriptLine] = []
    private var pendingChars = 0
    private var lastRun = Date.distantPast
    private var running = false
    private var checkedClaims: [String] = []

    public init() {}

    /// Human-readable availability of the Private Cloud Compute model.
    public static func availabilityDescription() -> String? {
        let model = PrivateCloudComputeLanguageModel()
        switch model.availability {
        case .available:
            if model.quotaUsage.isLimitReached { return "Das Tageskontingent der Private Cloud Compute ist aufgebraucht." }
            return nil
        case .unavailable(.deviceNotEligible):
            return "Dieses Gerät unterstützt Private Cloud Compute nicht."
        case .unavailable(.systemNotReady):
            return "Das System ist noch nicht bereit. Bitte später erneut versuchen."
        case .unavailable:
            return "Private Cloud Compute ist nicht verfügbar."
        }
    }

    public func setEnabled(_ on: Bool) {
        if on {
            if let reason = Self.availabilityDescription() { status = .unavailable(reason) } else { status = .idle }
        } else {
            status = .off
            pending.removeAll()
            pendingChars = 0
        }
    }

    public func reset() {
        cards = []
        ideas = []
        pending = []
        pendingChars = 0
        checkedClaims = []
        lastError = nil
        lastRun = .distantPast
    }

    public func restore(cards: [FactCard], ideas: [IdeaCard]) {
        self.cards = cards
        self.ideas = ideas
        checkedClaims = cards.map(\.claim)
    }

    /// Called for every finished sentence (own and remote).
    public func ingest(_ line: TranscriptLine, topic: String) {
        guard status != .off else { return }
        pending.append(line)
        pendingChars += line.text.count
        let due = pendingChars >= 260 || (pendingChars >= 120 && Date().timeIntervalSince(lastRun) > 90)
        if due, Date().timeIntervalSince(lastRun) > 40 { Task { await run(topic: topic) } }
    }

    private func run(topic: String) async {
        guard !running, status == .idle || { if case .paused = status { return true } else { return false } }() else { return }
        if let reason = Self.availabilityDescription() {
            status = .unavailable(reason)
            return
        }
        running = true
        status = .checking
        lastRun = Date()
        let batch = pending
        pending = []
        pendingChars = 0
        defer { running = false }

        let excerpt = batch.map { "\($0.speakerName): \($0.text)" }.joined(separator: "\n")
        let known = checkedClaims.suffix(12).joined(separator: "; ")
        let instructions = """
        Du bist Faktenprüfer für einen deutschsprachigen Podcast. Das Thema der Folge: \(topic).
        Du bekommst einen Ausschnitt des Gesprächs (automatisch transkribiert, kleine Fehler möglich).
        1. Wähle nur überprüfbare Tatsachenbehauptungen aus und prüfe sie mit den Werkzeugen (zuerst wikipedia_suche, bei Bedarf web_kurzantwort). Bewerte nur, was die Suchergebnisse belegen. Wenn nichts Belastbares zu finden ist, wähle uncertain.
        2. Schlage höchstens drei weitere interessante Fakten zum Thema vor, die im Gespräch noch nicht vorkamen und die du in den Suchergebnissen gefunden hast.
        Erfinde keine Quellen und keine URLs. Antworte auf Deutsch.
        """
        do {
            let session = LanguageModelSession(model: PrivateCloudComputeLanguageModel(),
                                               tools: [WikipediaSearchTool(), WebAnswerTool()],
                                               instructions: instructions)
            let prompt = """
            Bereits geprüft (nicht wiederholen): \(known.isEmpty ? "nichts" : known)

            Gesprächsausschnitt:
            \(excerpt)
            """
            let response = try await session.respond(to: prompt, generating: FactCheckReport.self)
            let at = batch.last?.at ?? 0
            let newCards = response.content.claims.map { claim in
                FactCard(claim: claim.claim,
                         verdict: claim.verdict == .confirmed ? .confirmed : claim.verdict == .doubtful ? .doubtful : .uncertain,
                         note: claim.note, sourceTitle: claim.sourceTitle,
                         sourceURL: claim.sourceURL.flatMap(URL.init(string:)), at: at)
            }
            cards.insert(contentsOf: newCards.reversed(), at: 0)
            checkedClaims.append(contentsOf: newCards.map(\.claim))
            let knownTitles = Set(ideas.map { $0.title.lowercased() })
            for idea in response.content.ideas where !knownTitles.contains(idea.title.lowercased()) {
                ideas.insert(IdeaCard(title: idea.title, detail: idea.detail, sourceURL: idea.sourceURL.flatMap(URL.init(string:))), at: 0)
            }
            lastError = nil
            status = .idle
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            switch error {
            case .quotaLimitReached:
                status = .paused("Das Tageskontingent der Private Cloud Compute ist aufgebraucht.")
            case .networkFailure:
                status = .paused("Keine Verbindung. Der Faktencheck versucht es später erneut.")
                pending = batch + pending
            case .serviceUnavailable:
                status = .paused("Der Dienst ist gerade nicht erreichbar.")
                pending = batch + pending
            @unknown default:
                status = .paused("Unbekannter Fehler der Private Cloud Compute.")
            }
            lastError = error.localizedDescription
        } catch {
            lastError = error.localizedDescription
            status = .idle
        }
    }

    /// Manual trigger ("Jetzt prüfen").
    public func checkNow(topic: String) {
        lastRun = .distantPast
        Task { await run(topic: topic) }
    }
}
#endif
