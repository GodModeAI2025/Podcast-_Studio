import StudioCore
import StudioServices
import SwiftUI

/// Markdown script: rendered reader for everybody, editor for the owner (MVP: only the
/// owner edits). The owner's reading position is mirrored to all participants.
struct ScriptPanel: View {
    @Environment(StudioController.self) private var studio
    @State private var editing = false
    @State private var draft = ""
    @State private var localSection = 0

    private var activeSection: Int {
        studio.isOwner || !studio.followOwner ? localSection : studio.ownerSection
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: draft) { _, text in studio.updateScript(text) }
            } else {
                reader
            }
        }
        .onChange(of: studio.ownerSection) { _, s in if !studio.isOwner { localSection = s } }
    }

    private var header: some View {
        HStack {
            Label("Drehbuch", systemImage: "text.alignleft").font(.headline)
            Text("Rev. \(studio.script.revision)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if studio.isOwner {
                Toggle(isOn: $editing) { Label(editing ? "Fertig" : "Bearbeiten", systemImage: "pencil") }
                    .toggleStyle(.button)
                    .onChange(of: editing) { _, on in if on { draft = studio.script.markdown } }
            } else {
                Toggle(isOn: Bindable(studio).followOwner) { Label("Folgen", systemImage: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("Automatisch zur Stelle scrollen, die der Host gerade liest")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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
                .padding()
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: activeSection) { _, section in
                guard let first = studio.parsedScript.sections.first(where: { $0.id == section })?.firstBlock else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(first, anchor: .top) }
            }
            .overlay(alignment: .bottomTrailing) {
                if studio.isOwner { sectionStepper.padding() }
            }
        }
    }

    /// Owner: step through sections (teleprompter style).
    private var sectionStepper: some View {
        HStack(spacing: 4) {
            Button { step(-1) } label: { Image(systemName: "chevron.up") }
            Button { step(1) } label: { Image(systemName: "chevron.down") }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
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
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(highlighted ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                if highlighted {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .heading(let level):
            Text(inline(block.text)).font(level == 1 ? .largeTitle.bold() : level == 2 ? .title2.bold() : .title3.weight(.semibold))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph:
            Text(inline(block.text)).font(.title3)
        case .bullet:
            HStack(alignment: .firstTextBaseline) { Text("•"); Text(inline(block.text)) }.font(.title3)
        case .numbered(let n):
            HStack(alignment: .firstTextBaseline) { Text("\(n)."); Text(inline(block.text)) }.font(.title3)
        case .quote:
            Text(inline(block.text)).font(.title3.italic()).foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary).frame(width: 2) }
        case .code:
            Text(block.text).font(.system(.body, design: .monospaced))
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
    }
}
