import AppKit
import SwiftUI
import MurmurCore

/// Actions the pill's hover quick-buttons trigger (wired by AppDelegate).
struct PillActions {
    var handsFreeToggle: () -> Void = {}
    var cancelDictation: () -> Void = {}
    var confirmDictation: () -> Void = {}
    var openScratchpad: () -> Void = {}
    var openSettings: () -> Void = {}
    var setLanguage: (String) -> Void = { _ in }
    var currentLanguage: () -> String = { "en-US" }
}

/// Wispr-style pill at the bottom-center of the screen: a collapsed sliver
/// when idle, quick actions on hover, cancel · waveform · confirm while
/// recording. A non-activating panel — it never steals focus from the app
/// being dictated into.
@MainActor
final class RecordingPillController {

    @Observable
    final class Model {
        enum Phase { case collapsed, hover, recording, processing }
        var phase: Phase = .collapsed
        var level: Float = 0
        var actions = PillActions()
    }

    private var panel: NSPanel?
    private let model = Model()

    init(actions: PillActions) {
        model.actions = actions
    }

    /// Called once at launch: the pill is always on screen from now on.
    func install() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
    }

    func transition(to state: DictationController.State) {
        switch state {
        case .recording:
            model.phase = .recording
        case .processing:
            model.phase = .processing
        case .injecting, .idle:
            model.phase = .collapsed
            model.level = 0
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 130),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // SwiftUI draws its own
        panel.level = .statusBar
        panel.ignoresMouseEvents = false // hover + buttons
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PillView(model: model))
        return panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 8))
    }
}

// MARK: - SwiftUI content

/// Dynamic-Island-style morphing: ONE persistent black capsule (`island`)
/// animates its frame between phases — sliver → mic button → wide recording
/// pill — while satellite buttons spring out from behind it and content
/// cross-fades inside it. Nothing is swapped in or out wholesale, so every
/// change is a smooth shape interpolation.
private struct PillView: View {
    @Bindable var model: RecordingPillController.Model
    @State private var supportedLanguages: [String] = []

    private var phase: RecordingPillController.Model.Phase { model.phase }

    private var spring: Animation { .spring(response: 0.38, dampingFraction: 0.72) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // "Dictate fn" label — grows up out of the island on hover.
            dictateLabel
                .padding(.bottom, 66)
                .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .bottom)
                .opacity(phase == .hover ? 1 : 0)
                .allowsHitTesting(phase == .hover)

            // Satellite quick-action buttons — emerge from behind the island.
            satellite(targetX: -84, index: 0) {
                languageMenu
            }
            satellite(targetX: 28, index: 1) {
                circleButton("note.text") { model.actions.openScratchpad() }
            }
            satellite(targetX: 84, index: 2) {
                circleButton("gearshape.fill") { model.actions.openSettings() }
            }

            island
        }
        .frame(width: 460, height: 130, alignment: .bottom)
        .padding(.bottom, 6)
        .animation(spring, value: phase)
        .onHover { hovering in
            switch (hovering, phase) {
            case (true, .collapsed): model.phase = .hover
            case (false, .hover): model.phase = .collapsed
            default: break
            }
        }
        .task {
            // Long-term this could come from SpeechTranscriber.supportedLocales;
            // a short curated list keeps the hover menu instant.
            supportedLanguages = ["en-US", "es-ES", "fr-FR", "de-DE", "pt-BR", "it-IT", "ja-JP"]
        }
    }

    // MARK: The island — one capsule, four sizes

    private var islandSize: CGSize {
        switch phase {
        case .collapsed: CGSize(width: 64, height: 10)
        case .hover: CGSize(width: 44, height: 44)      // becomes the mic button
        case .recording: CGSize(width: 260, height: 52)
        case .processing: CGSize(width: 150, height: 44)
        }
    }

    /// In hover the island sits where the mic button belongs (slot -28);
    /// otherwise it is centered.
    private var islandX: CGFloat { phase == .hover ? -28 : 0 }

    private var island: some View {
        Capsule()
            .fill(.black.opacity(0.9))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .frame(width: islandSize.width, height: islandSize.height)
            .overlay(islandContent)
            .contentShape(Capsule().scale(phase == .collapsed ? 2.2 : 1))
            .shadow(color: .black.opacity(phase == .collapsed ? 0 : 0.35),
                    radius: 14, y: 5)
            .offset(x: islandX)
            .onTapGesture {
                if phase == .hover { model.actions.handsFreeToggle() }
            }
    }

    @ViewBuilder private var islandContent: some View {
        switch phase {
        case .collapsed:
            EmptyView()
        case .hover:
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .transition(.opacity)
        case .recording:
            HStack(spacing: 14) {
                Button { model.actions.cancelDictation() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)

                WaveDots(level: model.level)

                Button { model.actions.confirmDictation() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Polishing…")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.08)))
        }
    }

    // MARK: Satellites

    /// A quick-action circle that springs out from the island's hover slot,
    /// staggered per index so the row reads as a split.
    private func satellite(targetX: CGFloat, index: Int, @ViewBuilder content: () -> some View) -> some View {
        content()
            .offset(x: phase == .hover ? targetX : islandXWhenHidden)
            .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .center)
            .opacity(phase == .hover ? 1 : 0)
            .allowsHitTesting(phase == .hover)
            .animation(spring.delay(phase == .hover ? Double(index) * 0.045 : 0), value: phase)
    }

    /// Where satellites hide: tucked behind the island's resting spot.
    private var islandXWhenHidden: CGFloat { 0 }

    private var languageMenu: some View {
        Menu {
            ForEach(supportedLanguages, id: \.self) { lang in
                Button {
                    model.actions.setLanguage(lang)
                } label: {
                    if lang == model.actions.currentLanguage() {
                        Label(displayName(lang), systemImage: "checkmark")
                    } else {
                        Text(displayName(lang))
                    }
                }
            }
        } label: {
            circleIcon("globe")
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleIcon(symbol) }
            .buttonStyle(.plain)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.9), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Circle())
    }

    private var dictateLabel: some View {
        HStack(spacing: 4) {
            Text("Dictate")
                .foregroundStyle(.white)
            Text("fn")
                .foregroundStyle(LinearGradient(
                    colors: [Color(red: 0.9, green: 0.7, blue: 1.0), Color(red: 0.7, green: 0.5, blue: 1.0)],
                    startPoint: .leading, endPoint: .trailing))
                .fontWeight(.bold)
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.92), in: Capsule())
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Mic-level-driven dotted waveform (the Wispr look).
private struct WaveDots: View {
    let level: Float
    @State private var history: [Float] = Array(repeating: 0, count: 14)

    var body: some View {
        HStack(spacing: 4) {
            ForEach(history.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 4, height: max(4, CGFloat(history[i]) * 22))
            }
        }
        .frame(height: 24)
        .onChange(of: level) {
            history.removeFirst()
            history.append(level)
        }
        .animation(.linear(duration: 0.08), value: history)
    }
}
