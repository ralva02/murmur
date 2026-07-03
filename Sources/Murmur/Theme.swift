import SwiftUI

/// Murmur's design language, matched to the Wispr Flow dashboard aesthetic:
/// warm cream canvas, white content cards, editorial serif display lines,
/// black pill actions, violet brand accent.
enum Theme {
    // Canvas & surfaces
    static let canvas = Color(red: 0.949, green: 0.945, blue: 0.929)      // warm cream
    static let sidebarSelection = Color(red: 0.906, green: 0.898, blue: 0.875)
    static let card = Color(red: 0.993, green: 0.991, blue: 0.985)        // near-white, warm
    static let cardBorder = Color.black.opacity(0.07)
    static let rowSeparator = Color.black.opacity(0.06)

    // Ink
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.11)
    static let inkSecondary = Color(red: 0.44, green: 0.43, blue: 0.40)
    static let inkTertiary = Color(red: 0.62, green: 0.60, blue: 0.56)

    // Accents
    static let violet = Color(red: 0.42, green: 0.24, blue: 0.82)
    static let heroTop = Color(red: 0.17, green: 0.13, blue: 0.32)        // deep indigo
    static let heroBottom = Color(red: 0.33, green: 0.20, blue: 0.55)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Building blocks

/// White rounded content card.
struct CardStyle: ViewModifier {
    var padding: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 0) -> some View { modifier(CardStyle(padding: padding)) }
}

/// The black "Add new"-style primary action.
struct PrimaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(red: 0.98, green: 0.97, blue: 0.95))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Quiet bordered secondary action.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.card.opacity(configuration.isPressed ? 0.6 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
    }
}

/// Flow-style underlined tab strip.
struct UnderlineTabs: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 24) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    VStack(spacing: 7) {
                        Text(titles[i])
                            .font(.system(size: 14, weight: selection == i ? .semibold : .regular))
                            .foregroundStyle(selection == i ? Theme.ink : Theme.inkSecondary)
                        Rectangle()
                            .fill(selection == i ? Theme.ink : .clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
        }
    }
}

/// Dark editorial hero banner with a serif headline (the "Flow spells the way
/// you do." card).
struct HeroBanner<Extra: View>: View {
    let headline: String
    let emphasis: String?      // rendered in italic within the headline
    let subtitle: String
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headlineText
                .font(Theme.serif(26))
                .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.90))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.97, green: 0.95, blue: 0.90).opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            extra
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var headlineText: Text {
        guard let emphasis, let range = headline.range(of: emphasis) else {
            return Text(headline)
        }
        let before = String(headline[..<range.lowerBound])
        let after = String(headline[range.upperBound...])
        return Text(before) + Text(emphasis).italic() + Text(after)
    }
}

/// Page chrome: title row with optional trailing action, then content.
struct Page<Content: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    trailing
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
