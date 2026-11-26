import SwiftUI

/// The help pages, bundled from spec/help/<language>/*.md so every platform shares one text.
struct HelpView: View {
    struct Page: Identifiable, Hashable {
        var id: String { file }
        let file: String
        let title: String
        let body: String
    }

    @State private var pages: [Page] = []
    @State private var selection: Page.ID?

    var body: some View {
        NavigationSplitView {
            List(pages, selection: $selection) { Text($0.title).tag($0.id) }
                .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            if let page = pages.first(where: { $0.id == selection }) {
                ScrollView {
                    MarkdownText(markdown: page.body)
                        .frame(maxWidth: 640, alignment: .leading)
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Choose a Topic", systemImage: "questionmark.circle")
            }
        }
        .onAppear {
            pages = Self.loadPages()
            selection = selection ?? pages.first?.id
        }
    }

    static func loadPages() -> [Page] {
        let language = Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en"
        guard let folder = Bundle.main.url(forResource: language, withExtension: nil, subdirectory: "help"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let title = text.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? url.lastPathComponent
            return Page(file: url.lastPathComponent, title: title, body: text)
        }
    }
}

/// Renders the help Markdown block by block: headings, paragraphs, lists, images from the bundle.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text)).font(level == 1 ? .largeTitle.weight(.semibold) : level == 2 ? .title2.weight(.semibold) : .headline)
                        .padding(.top, level == 1 ? 0 : 8)
                case .paragraph(let text):
                    Text(inline(text)).fixedSize(horizontal: false, vertical: true)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Text(inline(text)).fixedSize(horizontal: false, vertical: true) }
                case .code(let text):
                    Text(text).font(.callout.monospaced()).textSelection(.enabled).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
                case .image(let alt, let path):
                    if let url = Bundle.main.url(forResource: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                                 withExtension: (path as NSString).pathExtension,
                                                 subdirectory: ("help/" + path as NSString).deletingLastPathComponent),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 600)
                            .clipShape(.rect(cornerRadius: 8)).accessibilityLabel(Text(alt))
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    enum Block { case heading(Int, String), paragraph(String), bullet(String), code(String), image(String, String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() { if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] } }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { result.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("<!--") && line.hasSuffix("-->") { continue }  // authoring notes, e.g. screenshot TODOs
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                result.append(.heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); result.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("!["), let close = line.firstIndex(of: "]"), let open = line.firstIndex(of: "("), line.hasSuffix(")") {
                flush()
                let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<close])
                let path = String(line[line.index(after: open)..<line.index(before: line.endIndex)])
                result.append(.image(alt, path))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
