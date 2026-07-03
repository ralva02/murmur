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
    private var followTimer: Timer?

    init(actions: PillActions) {
        model.actions = actions
    }

    /// Called once at launch: the pill is always on screen from now on.
    func install() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()

        // Keep the collapsed sliver on whichever display the pointer is on.
        // (Hover and recording can only start where the pill already is, so
        // only the idle state needs to follow the mouse across screens.)
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.model.phase == .collapsed else { return }
                self.reposition()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    func transition(to state: DictationController.State) {
        switch state {
        case .recording:
            reposition()   // dictation may target a different display
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
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let panel, let screen else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 8)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
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
    @State private var hovered: QuickAction? = nil

    /// The hover row's quick actions; rawValue is the slot order.
    enum QuickAction: Int {
        case language, dictate, scratchpad, settings

        var slotX: CGFloat {
            switch self {
            case .language: -66
            case .dictate: -22
            case .scratchpad: 22
            case .settings: 66
            }
        }
    }

    private var phase: RecordingPillController.Model.Phase { model.phase }

    private var spring: Animation { .spring(response: 0.3, dampingFraction: 0.75) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Explainer label — sits above the hovered button (mic by default)
            // and slides between slots.
            explainerLabel
                .padding(.bottom, 56)
                .offset(x: (hovered ?? .dictate).slotX)
                .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .bottom)
                .opacity(phase == .hover ? 1 : 0)
                .allowsHitTesting(false)

            // Satellite quick-action buttons — emerge from behind the island.
            satellite(.language, index: 0) {
                languageMenu
            }
            satellite(.scratchpad, index: 1) {
                circleButton("note.text") { model.actions.openScratchpad() }
            }
            satellite(.settings, index: 2) {
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
        case .collapsed: CGSize(width: 44, height: 7)
        case .hover: CGSize(width: 36, height: 36)      // becomes the mic button
        case .recording: CGSize(width: 260, height: 52)
        case .processing: CGSize(width: 150, height: 44)
        }
    }

    /// In hover the island sits where the mic button belongs;
    /// otherwise it is centered.
    private var islandX: CGFloat { phase == .hover ? QuickAction.dictate.slotX : 0 }

    private var island: some View {
        Capsule()
            // Collapsed: a lighter contrasting gray (a black sliver vanishes
            // against dark docks/menu bars — Wispr does the same).
            .fill(phase == .collapsed ? Color(white: 0.32).opacity(0.95) : .black.opacity(0.9))
            .overlay(Capsule().strokeBorder(.white.opacity(phase == .collapsed ? 0.06 : 0.12), lineWidth: 0.5))
            .frame(width: islandSize.width, height: islandSize.height)
            .overlay(islandContent)
            .contentShape(Capsule().scale(phase == .collapsed ? 2.2 : 1))
            .shadow(color: .black.opacity(phase == .collapsed ? 0 : 0.35),
                    radius: 14, y: 5)
            .offset(x: islandX)
            .onTapGesture {
                if phase == .hover { model.actions.handsFreeToggle() }
            }
            .onHover { inside in
                guard phase == .hover else { return }
                if inside { hovered = .dictate }
            }
    }

    @ViewBuilder private var islandContent: some View {
        switch phase {
        case .collapsed:
            EmptyView()
        case .hover:
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .medium))
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
    private func satellite(_ action: QuickAction, index: Int, @ViewBuilder content: () -> some View) -> some View {
        content()
            .offset(x: phase == .hover ? action.slotX : 0)
            .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .center)
            .opacity(phase == .hover ? 1 : 0)
            .allowsHitTesting(phase == .hover)
            .animation(spring.delay(phase == .hover ? Double(index) * 0.04 : 0), value: phase)
            .onHover { inside in
                guard phase == .hover else { return }
                if inside { hovered = action } else if hovered == action { hovered = nil }
            }
    }

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
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.9), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(Circle())
    }

    /// "Polish ⌥1"-style label: name in white, shortcut in the pink-violet
    /// gradient. Content follows whichever button is hovered.
    private var explainerLabel: some View {
        let (name, shortcut) = explainerText
        return HStack(spacing: 5) {
            Text(name)
                .foregroundStyle(.white)
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 0.9, green: 0.7, blue: 1.0), Color(red: 0.7, green: 0.5, blue: 1.0)],
                        startPoint: .leading, endPoint: .trailing))
                    .fontWeight(.bold)
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
        .background(.black.opacity(0.92), in: Capsule())
        .fixedSize()
    }

    private var explainerText: (String, String?) {
        switch hovered ?? .dictate {
        case .language: ("Language", nil)
        case .dictate: ("Dictate", "fn")
        case .scratchpad: ("Scratchpad", "⌃⌥N")
        case .settings: ("Settings", nil)
        }
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
