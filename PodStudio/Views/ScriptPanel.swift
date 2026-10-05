import StudioCore
import StudioServices
import SwiftUI
import UniformTypeIdentifiers

/// Markdown script: rendered reader for everybody, editor for the owner (MVP: only the
/// owner edits). The owner's reading position is mirrored to all participants.
/// Headings in Courier uppercase (chrome), running text proportional (read).
struct ScriptPanel: View {
    @Environment(StudioController.self) private var studio
    @State private var editing = false
    @State private var draft = ""
    @State private var localSection = 0
    @State private var importing = false

    private var activeSection: Int {
        studio.isOwner || !studio.followOwner ? localSection : studio.ownerSection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Arcade.ink)
                    .scrollContentBackground(.hidden)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: Arcade.radius, style: .continuous).fill(Arcade.field))
                    .overlay(RoundedRectangle(cornerRadius: Arcade.radius, style: .continuous).strokeBorder(Arcade.hairline, lineWidth: 1))
                    .padding(18)
                    .onChange(of: draft) { _, text in studio.updateScript(text) }
            } else {
                reader
            }
        }
        .onChange(of: studio.ownerSection) { _, s in if !studio.isOwner { localSection = s } }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType("net.daringfireball.markdown"), .plainText, .text].compactMap { $0 }) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                studio.errorMessage = "Die Datei konnte nicht gelesen werden."
                return
            }
            draft = text
            studio.updateScript(text)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow("Drehbuch · Rev. \(studio.script.revision)")
                if let title = studio.parsedScript.sections.first(where: { $0.id == activeSection })?.title {
                    Text(title)
                        .font(Arcade.chrome(14, weight: .heavy))
                        .foregroundStyle(Arcade.ink)
                        .lineLimit(1)
                }
            }
            Spacer()
            if studio.isOwner {
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.arcade(.ghost, compact: true))
                    .accessibilityLabel("Markdown-Datei importieren")
                Button(editing ? "Fertig" : "Bearbeiten") {
                    if !editing { draft = studio.script.markdown }
                    editing.toggle()
                }
                .buttonStyle(.arcade(editing ? .primary : .ghost, compact: true))
            } else {
                Button(studio.followOwner ? "Folge Host" : "Frei lesen") { studio.followOwner.toggle() }
                    .buttonStyle(.arcade(studio.followOwner ? .primary : .ghost, compact: true))
                    .help("Automatisch zur Stelle scrollen, die der Host gerade liest")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Arcade.hairline).frame(height: 1) }
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(studio.parsedScript.blocks) { block in
                        BlockView(block: block, highlighted: block.section == activeSection)
                            .id(block.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                localSection = block.section
                                if studio.isOwner { studio.setReadingSection(block.section) }
                            }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeSection) { _, section in
                guard let first = studio.parsedScript.sections.first(where: { $0.id == section })?.firstBlock else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(first, anchor: .top) }
            }
            .overlay(alignment: .bottomTrailing) {
                if studio.isOwner { sectionStepper.padding(20) }
            }
        }
    }

    /// Owner: step through sections (teleprompter style).
    private var sectionStepper: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.arcade(.ghost, compact: true))
            Button { step(1) } label: { Label("Weiter", systemImage: "chevron.down") }.buttonStyle(.arcade(.primary, compact: true))
                .keyboardShortcut(.downArrow, modifiers: [.command])
        }
    }

    private func step(_ delta: Int) {
        let count = studio.parsedScript.sections.count
        guard count > 0 else { return }
        localSection = min(max(localSection + delta, 0), count - 1)
        studio.setReadingSection(localSection)
    }
}

private struct BlockView: View {
    let block: ScriptBlock
    let highlighted: Bool

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlighted ? Arcade.panelStrong.opacity(0.7) : .clear))
            .overlay(alignment: .leading) {
                Capsule().fill(highlighted ? Arcade.accent : .clear).frame(width: 4).padding(.vertical, 6)
            }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .heading(let level):
            Text(inline(block.text))
                .arcadeHeadline(level == 1 ? 30 : level == 2 ? 21 : 16,
                                color: level <= 2 ? Arcade.accent : Arcade.line,
                                shadow: level == 1 ? 4 : 2)
                .padding(.top, level <= 2 ? 14 : 6)
        case .paragraph:
            Text(inline(block.text)).font(Arcade.read(.title3)).foregroundStyle(Arcade.ink)
                .lineSpacing(5)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").font(Arcade.chrome(18)).foregroundStyle(Arcade.accent)
                Text(inline(block.text)).font(Arcade.read(.title3)).foregroundStyle(Arcade.ink)
            }
        case .numbered(let n):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", n)).font(Arcade.chrome(15, weight: .heavy)).foregroundStyle(Arcade.line)
                Text(inline(block.text)).font(Arcade.read(.title3)).foregroundStyle(Arcade.ink)
            }
        case .quote:
            // `.lp-quote`: coloured top edge, big quote mark, Courier bold in accent colour.
            VStack(alignment: .leading, spacing: 4) {
                Text("“").font(Arcade.chrome(44, weight: .heavy)).foregroundStyle(Arcade.accentHot.opacity(0.55))
                    .frame(height: 22, alignment: .top)
                Text(inline(block.text))
                    .font(Arcade.chrome(20, weight: .semibold))
                    .foregroundStyle(Arcade.accent)
            }
            .arcadePanel(accentTop: Arcade.accentHot, padding: 16)
            .padding(.vertical, 4)
        case .code:
            Text(block.text).font(.system(.body, design: .monospaced))
                .foregroundStyle(Arcade.ink)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Arcade.field)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .rule:
            Rectangle().fill(Arcade.hairline).frame(height: 1).padding(.vertical, 10)
        }
    }

    private func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
