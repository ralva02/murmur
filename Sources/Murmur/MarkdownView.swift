import SwiftUI

/// Block-level markdown rendering for summaries. SwiftUI's
/// AttributedString(markdown:) only handles inline syntax — headings and
/// list markers come through as literal text — so blocks are parsed here
/// and styled with the Theme; inline bold/italic/code still go through
/// AttributedString per line.
struct MarkdownView: View {
    let markdown: String

    private enum Block {
        case heading(String, level: Int)
        case bullets([String])
        case numbered([String])
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let blocks = Self.parse(markdown)
            ForEach(blocks.indices, id: \.self) { index in
                view(for: blocks[index])
            }
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inline(text))
                .font(level <= 2 ? Theme.serif(16, .semibold) : .system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 6)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.violet)
                        Text(inline(items[i]))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .foregroundStyle(Theme.violet)
                            .monospacedDigit()
                        Text(inline(items[i]))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .paragraph(let text):
            Text(inline(text))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var paragraph: [String] = []

        func flush() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                flush()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(text, level: level))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                if !numbered.isEmpty || !paragraph.isEmpty { flush() }
                bullets.append(String(line.dropFirst(2)))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                if !bullets.isEmpty || !paragraph.isEmpty { flush() }
                numbered.append(String(line[range.upperBound...]))
            } else if !bullets.isEmpty && (line.hasPrefix("  ") || rawLine.hasPrefix("  ")) {
                // continuation of the previous bullet
                bullets[bullets.count - 1] += " " + line
            } else {
                if !bullets.isEmpty || !numbered.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
