import AppKit
import MurmurCore

/// Menu-bar presence (spec §12): state indicator, quick actions, permission
/// warnings, entry points to settings and recent activity.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dictation: DictationController
    private let store: AppStore
    private let openSettings: () -> Void
    private let openActivity: () -> Void
    private let openScratchpad: () -> Void
    private let toggleLongRecording: () -> Void
    private let longRecordingElapsed: () -> String?

    init(dictation: DictationController,
         store: AppStore,
         openSettings: @escaping () -> Void,
         openActivity: @escaping () -> Void,
         openScratchpad: @escaping () -> Void,
         toggleLongRecording: @escaping () -> Void,
         longRecordingElapsed: @escaping () -> String?) {
        self.dictation = dictation
        self.store = store
        self.openSettings = openSettings
        self.openActivity = openActivity
        self.openScratchpad = openScratchpad
        self.toggleLongRecording = toggleLongRecording
        self.longRecordingElapsed = longRecordingElapsed
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        update(for: .idle)
    }

    /// On notched MacBooks, status items that don't fit to the right of the
    /// notch are silently not rendered. Detectable: the button's window sits
    /// left of the top-right auxiliary area.
    var isHiddenByNotch: Bool {
        guard let window = statusItem.button?.window,
              let screen = window.screen ?? NSScreen.main,
              let rightArea = screen.auxiliaryTopRightArea
        else { return false }   // no notch on this screen
        return window.frame.minX < rightArea.minX
    }

    func update(for state: DictationController.State) {
        let image: NSImage? = switch state {
        case .idle: Permissions.allGranted
            ? MurmurIcon.idle
            : NSImage(systemSymbolName: "exclamationmark.triangle",
                      accessibilityDescription: "Murmur needs permissions")
        case .recording: MurmurIcon.recording
        case .processing: NSImage(systemSymbolName: "hourglass",
                                  accessibilityDescription: "Murmur processing")
        case .injecting: NSImage(systemSymbolName: "arrow.down.doc",
                                 accessibilityDescription: "Murmur inserting")
        }
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel("Murmur")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let elapsed = longRecordingElapsed() {
            menu.addItem(withTitle: "Stop Recording (\(elapsed))",
                         action: #selector(toggleLongRec), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Start Recording",
                         action: #selector(toggleLongRec), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())

        let recording = dictation.isRecording
        menu.addItem(withTitle: recording ? "Stop Hands-Free Dictation" : "Start Hands-Free Dictation",
                     action: #selector(toggleHandsFree), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Last Transcript",
                     action: #selector(pasteLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Last Transcript",
                     action: #selector(copyLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Undo Last Insertion",
                     action: #selector(undoLast), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Scratchpad…",
                     action: #selector(showScratchpad), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Recent Activity…",
                     action: #selector(showActivity), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…",
                     action: #selector(showSettings), keyEquivalent: ",").target = self

        if !Permissions.allGranted {
            menu.addItem(.separator())
            if !Permissions.accessibilityTrusted {
                menu.addItem(withTitle: "⚠️ Grant Accessibility Access…",
                             action: #selector(grantAccessibility), keyEquivalent: "").target = self
            }
            if !Permissions.inputMonitoringGranted {
                menu.addItem(withTitle: "⚠️ Grant Input Monitoring…",
                             action: #selector(grantInputMonitoring), keyEquivalent: "").target = self
            }
            if !Permissions.microphoneGranted {
                menu.addItem(withTitle: "⚠️ Grant Microphone Access…",
                             action: #selector(grantMicrophone), keyEquivalent: "").target = self
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Murmur",
                     action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func toggleLongRec() { toggleLongRecording() }
    @objc private func toggleHandsFree() { dictation.handsFreeToggle() }
    @objc private func pasteLast() { dictation.pasteLastTranscript() }
    @objc private func copyLast() { dictation.copyLastTranscript() }
    @objc private func showScratchpad() { openScratchpad() }
    @objc private func undoLast() { dictation.undoLastInsertion() }
    @objc private func showActivity() { openActivity() }
    @objc private func showSettings() { openSettings() }
    @objc private func grantAccessibility() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }
    @objc private func grantInputMonitoring() { Permissions.requestInputMonitoring(); Permissions.openInputMonitoringSettings() }
    @objc private func grantMicrophone() { Task { _ = await Permissions.requestMicrophone() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
