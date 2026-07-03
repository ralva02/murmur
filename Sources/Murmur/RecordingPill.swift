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

/// The hover row's quick actions; slotX is the button center offset from the
/// panel's horizontal center.
enum PillQuickAction: Int, CaseIterable {
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

/// Wispr-style pill at the bottom-center of the screen: a collapsed sliver
/// when idle, quick actions on hover, cancel · waveform · confirm while
/// recording. A non-activating panel — it never steals focus from the app
/// being dictated into.
///
/// Hover detection is deliberately AppKit-level (NSTrackingArea with
/// .activeAlways): SwiftUI's .onHover rides on key-window-dependent tracking
/// and fires unreliably in a non-activating panel that is never key.
@MainActor
final class RecordingPillController: NSObject {

    @Observable
    final class Model {
        enum Phase { case collapsed, hover, recording, processing }
        var phase: Phase = .collapsed
        var level: Float = 0
        var hoveredAction: PillQuickAction?
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

        // Hover + screen-follow via a cursor-position poll. Tracking areas
        // and SwiftUI .onHover both proved unreliable inside a non-activating
        // panel of a background (accessory) app; polling NSEvent.mouseLocation
        // ten times a second depends on nothing and costs nothing measurable.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollMouse() }
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
            model.hoveredAction = nil
        }
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    // MARK: Hover via cursor poll (see install())

    private var followTick = 0

    private func pollMouse() {
        guard let panel else { return }
        // Panel-local coordinates, origin bottom-left; (midX, 0) is the sliver spot.
        let mouse = NSEvent.mouseLocation
        let local = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let dx = local.x - panel.frame.width / 2

        switch model.phase {
        case .collapsed:
            // Only the sliver itself (plus a small grace margin) expands.
            if local.y >= 0 && local.y < 26 && abs(dx) < 34 {
                model.phase = .hover
            } else {
                followTick += 1
                if followTick >= 30 {   // every ~1.5 s: follow mouse across displays
                    followTick = 0
                    reposition()
                }
            }
        case .hover:
            if local.y < 0 || local.y > 95 || abs(dx) > 115 {
                model.phase = .collapsed
                model.hoveredAction = nil
            } else if local.y < 48 {
                model.hoveredAction = PillQuickAction.allCases.first { abs(dx - $0.slotX) <= 18 }
            }
        case .recording, .processing:
            break
        }
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
        // Full frame, not visibleFrame: the pill hugs the true bottom edge of
        // the screen (floating over the Dock, like Wispr), never above it.
        let frame = screen.frame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
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

    private var phase: RecordingPillController.Model.Phase { model.phase }

    private var spring: Animation { .spring(response: 0.3, dampingFraction: 0.75) }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Explainer label — sits above the hovered button (mic by default)
            // and slides between slots.
            explainerLabel
                .padding(.bottom, 43)   // buttons are 36 pt tall → 7 pt gap
                .offset(x: (model.hoveredAction ?? .dictate).slotX)
                .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .bottom)
                .opacity(phase == .hover ? 1 : 0)
                .allowsHitTesting(false)
                // Faster than the satellites: the label must feel glued to
                // the pointer as it skips between buttons.
                .animation(.spring(response: 0.2, dampingFraction: 0.85), value: model.hoveredAction)

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
        .padding(.bottom, 8)
        .animation(spring, value: phase)
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
        case .recording: CGSize(width: 110, height: 30)
        case .processing: CGSize(width: 128, height: 34)
        }
    }

    /// In hover the island sits where the mic button belongs;
    /// otherwise it is centered.
    private var islandX: CGFloat { phase == .hover ? PillQuickAction.dictate.slotX : 0 }

    private var island: some View {
        Capsule()
            .fill(.black.opacity(phase == .collapsed ? 0.85 : 0.9))
            // Wispr-style visible outline on the sliver; subtle on the rest.
            .overlay(Capsule().strokeBorder(
                .white.opacity(phase == .collapsed ? 0.45 : 0.12),
                lineWidth: phase == .collapsed ? 1 : 0.5))
            .frame(width: islandSize.width, height: islandSize.height)
            .overlay(islandContent)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .transition(.opacity)
        case .recording:
            // Just the waveform — release Fn to insert, Esc to cancel.
            WaveDots(level: model.level)
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.12)))
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Polishing…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.08)))
        }
    }

    // MARK: Satellites

    /// A quick-action circle that springs out from the island's hover slot,
    /// staggered per index so the row reads as a split.
    private func satellite(_ action: PillQuickAction, index: Int, @ViewBuilder content: () -> some View) -> some View {
        content()
            .offset(x: phase == .hover ? action.slotX : 0)
            .scaleEffect(phase == .hover ? 1 : 0.3, anchor: .center)
            .opacity(phase == .hover ? 1 : 0)
            .allowsHitTesting(phase == .hover)
            .animation(spring.delay(phase == .hover ? Double(index) * 0.04 : 0), value: phase)
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
        switch model.hoveredAction ?? .dictate {
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

/// Mic-level-driven equalizer: stationary bars that bounce in place with the
/// voice. Each tick carries the PEAK level since the last one — sampling the
/// instantaneous level would alias past syllables and detach the motion from
/// the speech rhythm. Per-bar jitter keeps the bounce organic; silence is a
/// flat dotted line.
private struct WaveDots: View {
    let level: Float
    @State private var heights: [Float] = Array(repeating: 0, count: 14)
    @State private var peak: Float = 0
    private let tick = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: max(3, CGFloat(heights[i]) * 16))
            }
        }
        .frame(height: 18)
        .onChange(of: level) { peak = max(peak, level) }
        .onReceive(tick) { _ in
            // sqrt lifts quiet speech into the visible range without
            // flattening loud peaks.
            let v = sqrt(min(peak * 1.5, 1))
            heights = heights.map { _ in v * Float.random(in: 0.55...1.0) }
            peak = level
        }
        .animation(.linear(duration: 0.05), value: heights)
    }
}
