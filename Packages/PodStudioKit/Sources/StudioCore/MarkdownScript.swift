import Foundation

/// Block-level Markdown model for the script reader.
///
/// SwiftUI renders inline formatting (`**bold**`, links …) per block via
/// `AttributedString(markdown:)`; this parser provides the block structure plus the
/// section index that drives auto-scroll and "current section" highlighting.
public struct ScriptBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case paragraph
        case bullet
        case numbered(Int)
        case quote
        case code
        case rule
    }

    public var id: Int
    public var kind: Kind
    /// Inline Markdown source (prefix markers stripped).
    public var text: String
    /// Index of the section the block belongs to. A section starts at every heading of
    /// level ≤ 2; content before the first heading is section 0.
    public var section: Int
}

public struct ScriptSection: Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var firstBlock: Int
}

public struct ParsedScript: Sendable, Equatable {
    public var blocks: [ScriptBlock]
    public var sections: [ScriptSection]

    public init(markdown: String) {
        var blocks: [ScriptBlock] = []
        var sections: [ScriptSection] = []
        var section = 0
        var paragraph: [String] = []
        var codeLines: [String]? = nil
        var sawHeading = false

        func add(_ kind: ScriptBlock.Kind, _ text: String) {
            blocks.append(ScriptBlock(id: blocks.count, kind: kind, text: text, section: section))
        }
        func flushParagraph() {
            if !paragraph.isEmpty {
                add(.paragraph, paragraph.joined(separator: " "))
                paragraph.removeAll()
            }
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if let code = codeLines {
                    add(.code, code.joined(separator: "\n"))
                    codeLines = nil
                } else {
                    flushParagraph()
                    codeLines = []
                }
                continue
            }
            if codeLines != nil {
                codeLines?.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let level = Self.headingLevel(line) {
                flushParagraph()
                let title = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                if level <= 2 {
                    // Content before the first heading stays section 0 only if it exists.
                    if sawHeading || !blocks.isEmpty { section += 1 }
                    sawHeading = true
                    sections.append(ScriptSection(id: section, title: title, firstBlock: blocks.count))
                }
                add(.heading(level: level), title)
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                add(.rule, "")
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                add(.bullet, String(line.dropFirst(2)))
                continue
            }
            if let (n, rest) = Self.numbered(line) {
                flushParagraph()
                add(.numbered(n), rest)
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                add(.quote, String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            paragraph.append(line)
        }
        if let code = codeLines { add(.code, code.joined(separator: "\n")) }
        flushParagraph()

        if sections.first?.id != 0 {
            sections.insert(ScriptSection(id: 0, title: "Start", firstBlock: 0), at: 0)
        }
        self.blocks = blocks
        self.sections = sections
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return hashes
    }

    private static func numbered(_ line: String) -> (Int, String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, let n = Int(digits) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (n, String(rest.dropFirst(2)))
    }
}
