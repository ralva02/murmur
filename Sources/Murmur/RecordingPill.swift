import AppKit
import SwiftUI

/// Floating pill at the bottom-center of the screen while dictating
/// (spec §12 Flow-Bubble equivalent). A non-activating panel: it never takes
/// focus away from the field being dictated into, and ignores clicks.
@MainActor
final class RecordingPillController {

    @Observable
    final class Model {
        enum Phase { case listening, processing }
        var phase: Phase = .listening
        var transcript: String = ""
    }

    private var panel: NSPanel?
    private let model = Model()

    func transition(to state: DictationController.State) {
        switch state {
        case .recording:
            model.phase = .listening
            model.transcript = ""
            show()
        case .processing:
            model.phase = .processing
        case .injecting, .idle:
            hide()
        }
    }

    func updateTranscript(_ text: String) {
        model.transcript = text
    }

    private func show() {
        if panel == nil { panel = makePanel() }
        reposition()
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the SwiftUI capsule draws its own
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
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
            y: frame.minY + 20))
    }
}

// MARK: - SwiftUI content

private struct PillView: View {
    @Bindable var model: RecordingPillController.Model

    var body: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .listening:
                PulsingDot()
                Text(displayText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
            case .processing:
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: 460, maxHeight: 56)
        .fixedSize()
        .frame(width: 460, height: 56, alignment: .bottom)
        .animation(.easeInOut(duration: 0.15), value: model.transcript)
    }

    private var displayText: String {
        model.transcript.isEmpty ? "Listening…" : String(model.transcript.suffix(58))
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .scaleEffect(pulsing ? 1.25 : 0.8)
            .opacity(pulsing ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
