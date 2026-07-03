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

private struct PillView: View {
    @Bindable var model: RecordingPillController.Model
    @State private var supportedLanguages: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch model.phase {
            case .collapsed:
                collapsedSliver
            case .hover:
                hoverStack
            case .recording:
                recordingPill
            case .processing:
                processingPill
            }
        }
        .frame(width: 460, height: 130, alignment: .bottom)
        .padding(.bottom, 6)
        .animation(.spring(duration: 0.35, bounce: 0.25), value: phaseKey)
        .onHover { hovering in
            switch (hovering, model.phase) {
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

    private var phaseKey: String {
        switch model.phase {
        case .collapsed: "collapsed"
        case .hover: "hover"
        case .recording: "recording"
        case .processing: "processing"
        }
    }

    private var collapsedSliver: some View {
        Capsule()
            .fill(.black.opacity(0.85))
            .frame(width: 64, height: 10)
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
            .contentShape(Capsule().scale(2.2))   // generous hover target
    }

    private var hoverStack: some View {
        VStack(spacing: 8) {
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

            HStack(spacing: 10) {
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
                    quickIcon("globe")
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Button { model.actions.handsFreeToggle() } label: { quickIcon("mic.fill", prominent: true) }
                    .buttonStyle(.plain)
                Button { model.actions.openScratchpad() } label: { quickIcon("note.text") }
                    .buttonStyle(.plain)
                Button { model.actions.openSettings() } label: { quickIcon("gearshape.fill") }
                    .buttonStyle(.plain)
            }
        }
    }

    private func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func quickIcon(_ symbol: String, prominent: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: prominent ? 16 : 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: prominent ? 52 : 40, height: 40)
            .background(.black.opacity(0.92), in: Capsule())
            .contentShape(Capsule())
    }

    private var recordingPill: some View {
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private var processingPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Polishing…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.black.opacity(0.92), in: Capsule())
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
