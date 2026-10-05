import Foundation

/// Shared Markdown script (Drehbuch). MVP rule: only the owner edits, everybody reads.
/// Conflict rule: the highest `revision` wins; equal or lower revisions are ignored.
public struct ScriptDocument: Codable, Sendable, Equatable {
    public private(set) var markdown: String
    public private(set) var revision: Int

    public init(markdown: String = "", revision: Int = 0) {
        self.markdown = markdown
        self.revision = revision
    }

    /// Applies a remote update. Returns `true` if the document changed.
    @discardableResult
    public mutating func apply(markdown: String, revision: Int) -> Bool {
        guard revision > self.revision else { return false }
        self.markdown = markdown
        self.revision = revision
        return true
    }

    /// Local edit (owner). Bumps the revision and returns the message to broadcast.
    public mutating func edit(_ newMarkdown: String) -> SessionMessage? {
        guard newMarkdown != markdown else { return nil }
        markdown = newMarkdown
        revision += 1
        return .script(markdown: markdown, revision: revision)
    }

    public var message: SessionMessage {
        .script(markdown: markdown, revision: revision)
    }

    public static let template = """
    # Neue Folge

    ## Intro
    Begrüßung, Thema der Folge, Gäste vorstellen.

    ## Teil 1
    - Frage 1
    - Frage 2

    ## Teil 2
    > Zitat oder Einspieler

    ## Outro
    Danke an die Gäste, Ausblick, Verabschiedung.
    """
}
