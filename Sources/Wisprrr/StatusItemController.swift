import AppKit
import WisprrrCore

/// Menu-bar presence (spec §12): state indicator, quick actions, permission
/// warnings, entry points to settings and recent activity.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let dictation: DictationController
    private let store: AppStore
    private let openSettings: () -> Void
    private let openActivity: () -> Void

    init(dictation: DictationController,
         store: AppStore,
         openSettings: @escaping () -> Void,
         openActivity: @escaping () -> Void) {
        self.dictation = dictation
        self.store = store
        self.openSettings = openSettings
        self.openActivity = openActivity
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        update(for: .idle)

        dictation.onStateChange = { [weak self] state in
            self?.update(for: state)
        }
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

    private func update(for state: DictationController.State) {
        let (symbol, description): (String, String) = switch state {
        case .idle: Permissions.allGranted
            ? ("mic", "Wisprrr idle")
            : ("exclamationmark.triangle", "Wisprrr needs permissions")
        case .recording: ("mic.fill", "Wisprrr recording")
        case .processing: ("hourglass", "Wisprrr processing")
        case .injecting: ("arrow.down.doc", "Wisprrr inserting")
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: description)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let recording = dictation.isRecording
        menu.addItem(withTitle: recording ? "Stop Hands-Free Dictation" : "Start Hands-Free Dictation",
                     action: #selector(toggleHandsFree), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Last Transcript",
                     action: #selector(pasteLast), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Undo Last Insertion",
                     action: #selector(undoLast), keyEquivalent: "").target = self
        menu.addItem(.separator())
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
        menu.addItem(withTitle: "Quit Wisprrr",
                     action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc private func toggleHandsFree() { dictation.handsFreeToggle() }
    @objc private func pasteLast() { dictation.pasteLastTranscript() }
    @objc private func undoLast() { dictation.undoLastInsertion() }
    @objc private func showActivity() { openActivity() }
    @objc private func showSettings() { openSettings() }
    @objc private func grantAccessibility() { Permissions.requestAccessibility(); Permissions.openAccessibilitySettings() }
    @objc private func grantInputMonitoring() { Permissions.requestInputMonitoring(); Permissions.openInputMonitoringSettings() }
    @objc private func grantMicrophone() { Task { _ = await Permissions.requestMicrophone() } }
    @objc private func quit() { NSApp.terminate(nil) }
}
