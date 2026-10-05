import Foundation

/// One finished sentence/segment of spoken text, transcribed on the speaker's own device.
public struct TranscriptLine: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var speakerID: UUID
    public var speakerName: String
    public var text: String
    /// Seconds since the start of the recording (shared clock).
    public var at: TimeInterval

    public init(id: UUID = UUID(), speakerID: UUID, speakerName: String, text: String, at: TimeInterval) {
        self.id = id
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.text = text
        self.at = at
    }
}

public enum FactVerdict: String, Codable, Sendable, Equatable {
    case confirmed
    case uncertain
    case doubtful
}

/// A spoken claim that was checked against research results.
public struct FactCard: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var claim: String
    public var verdict: FactVerdict
    public var note: String
    public var sourceTitle: String?
    public var sourceURL: URL?
    public var at: TimeInterval

    public init(id: UUID = UUID(), claim: String, verdict: FactVerdict, note: String,
                sourceTitle: String? = nil, sourceURL: URL? = nil, at: TimeInterval) {
        self.id = id
        self.claim = claim
        self.verdict = verdict
        self.note = note
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.at = at
    }
}

/// A further interesting fact the hosts could still mention.
public struct IdeaCard: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var detail: String
    public var sourceURL: URL?

    public init(id: UUID = UUID(), title: String, detail: String, sourceURL: URL? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sourceURL = sourceURL
    }
}

// MARK: - Script coverage

/// Which script sections were already spoken about, derived from the live transcript.
///
/// Matching is keyword based (German, light stemming): a section is "covered" when enough
/// of its distinctive words appeared in the transcript. Sections the reading position has
/// already passed without being covered are reported as "forgotten". Hints are only
/// meant to be shown while the episode is shorter than `hintLimit` (45 minutes).
public enum TopicCoverage {
    public static let hintLimit: TimeInterval = 45 * 60

    public enum Status: String, Sendable, Equatable {
        /// Still ahead of the reading position and not yet mentioned.
        case open
        /// Some keywords were mentioned.
        case partial
        /// Clearly covered.
        case covered
        /// The reading position moved on without this topic being covered.
        case forgotten
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: Int
        public var title: String
        public var keywords: [String]
        public var missing: [String]
        public var ratio: Double
        public var status: Status
    }

    public struct Report: Sendable, Equatable {
        public var entries: [Entry]
        /// False once the episode runs 45 minutes or longer: no hints any more.
        public var showsHints: Bool

        public func status(for section: Int) -> Status? {
            guard showsHints else { return nil }
            return entries.first { $0.id == section }?.status
        }

        public var forgotten: [Entry] { showsHints ? entries.filter { $0.status == .forgotten } : [] }
        public var open: [Entry] { showsHints ? entries.filter { $0.status == .open || $0.status == .partial } : [] }
    }

    public static func evaluate(script: ParsedScript, transcript: String, readingSection: Int,
                                elapsed: TimeInterval) -> Report {
        let spoken = Set(tokens(transcript).map(stem))
        var entries: [Entry] = []
        var rows: [(ScriptSection, [String], [String], Double)] = []
        for section in script.sections {
            let (keywords, weights) = keywords(for: section, in: script)
            guard keywords.count >= 2 else { continue }
            var matchedWeight = 0.0
            var missing: [String] = []
            for (word, weight) in zip(keywords, weights) {
                if isSpoken(stem(word), in: spoken) { matchedWeight += weight } else { missing.append(word) }
            }
            let total = weights.reduce(0, +)
            rows.append((section, keywords, missing, total > 0 ? matchedWeight / total : 0))
        }
        // The conversation has moved on past a section when the reading position or a later,
        // clearly covered section lies beyond it.
        let frontier = max(readingSection, rows.filter { $0.3 >= 0.5 }.map { $0.0.id }.max() ?? 0)
        for (section, keywords, missing, ratio) in rows {
            var status: Status = ratio >= 0.5 ? .covered : ratio >= 0.2 ? .partial : .open
            if status != .covered, section.id < frontier { status = .forgotten }
            entries.append(Entry(id: section.id, title: section.title, keywords: keywords,
                                 missing: missing, ratio: ratio, status: status))
        }
        return Report(entries: entries, showsHints: elapsed < hintLimit)
    }

    // MARK: Keywords

    private static func keywords(for section: ScriptSection, in script: ParsedScript) -> ([String], [Double]) {
        var weight: [String: Double] = [:]
        var order: [String] = []
        func add(_ text: String, _ w: Double) {
            for token in tokens(text) {
                let key = stem(token)
                if weight[key] == nil { order.append(key) }
                weight[key, default: 0] += w
            }
        }
        add(section.title, 2)
        for block in script.blocks where block.section == section.id {
            if case .heading = block.kind { continue }
            if case .rule = block.kind { continue }
            add(block.text, 1)
        }
        let ranked = order.sorted { (weight[$0] ?? 0) > (weight[$1] ?? 0) }.prefix(14)
        let words = Array(ranked)
        return (words, words.map { weight[$0] ?? 1 })
    }

    private static let stopwords: Set<String> = [
        "aber", "alle", "allem", "allen", "aller", "alles", "also", "andere", "anderen", "auch", "dass", "dann",
        "dazu", "denn", "dein", "deine", "dieser", "diese", "diesem", "diesen", "dieses", "doch", "durch",
        "eine", "einem", "einen", "einer", "eines", "einige", "einmal", "etwas", "euch", "folgt", "fuer",
        "für", "gegen", "gibt", "habe", "haben", "hatte", "hier", "ihre", "ihren", "immer", "jede", "jeder",
        "kann", "kein", "keine", "können", "machen", "manche", "mehr", "mein", "meine", "muss", "müssen",
        "nach", "nicht", "noch", "oder", "schon", "sein", "seine", "sich", "sind", "soll", "sollen", "über",
        "unter", "viel", "viele", "vom", "von", "vor", "wann", "warum", "weil", "weiter", "welche", "wenn",
        "werden", "wieder", "wird", "wir", "wollen", "worden", "wurde", "zum", "zur", "zwischen",
        "thema", "folge", "frage", "fragen", "teil", "intro", "outro", "gäste", "gast",
    ]

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text.lowercased() {
            if ch.isLetter { current.append(ch) } else {
                if current.count >= 4, !stopwords.contains(current) { out.append(current) }
                current = ""
            }
        }
        if current.count >= 4, !stopwords.contains(current) { out.append(current) }
        return out
    }

    static func stem(_ word: String) -> String {
        var w = word.replacingOccurrences(of: "ß", with: "ss")
        for suffix in ["ungen", "ung", "heit", "keit", "lich", "isch", "ern", "en", "er", "es", "e", "n", "s"] {
            if w.hasSuffix(suffix), w.count - suffix.count >= 4 {
                w.removeLast(suffix.count)
                break
            }
        }
        return w
    }

    private static func isSpoken(_ stem: String, in spoken: Set<String>) -> Bool {
        if spoken.contains(stem) { return true }
        guard stem.count >= 6 else { return false }
        let prefix = String(stem.prefix(6))
        return spoken.contains { $0.count >= 6 && $0.hasPrefix(prefix) }
    }
}
