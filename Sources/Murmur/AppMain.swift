import AppKit
import SwiftUI
import MurmurCore

/// Menu-bar app shell: builds the store, controller, listener, and UI.
@MainActor
enum AppMain {
    static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var store: AppStore!
    private var dictation: DictationController!
    private var hotkeys: HotkeyListener!
    private var statusController: StatusItemController!
    private var pill: RecordingPillController!
    private var mainWindow: NSWindow?
    private var mainModel: MainModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diag.app.notice("launch: accessibility=\(Permissions.accessibilityTrusted) inputMonitoring=\(Permissions.inputMonitoringGranted) microphone=\(Permissions.microphoneGranted)")
        AppStore.migrateLegacyDataIfNeeded()
        store = AppStore()
        dictation = DictationController(store: store)

        statusController = StatusItemController(
            dictation: dictation,
            store: store,
            openSettings: { [weak self] in self?.showSettings() },
            openActivity: { [weak self] in self?.showActivity() },
            openScratchpad: { [weak self] in self?.showScratchpad() })

        pill = RecordingPillController()
        dictation.onStateChange = { [weak self] state in
            self?.statusController.update(for: state)
            self?.pill.transition(to: state)
        }
        dictation.onPartialTranscript = { [weak self] text in
            self?.pill.updateTranscript(text)
        }

        // First-run permission prompts (spec §17: app keeps running regardless).
        if !Permissions.accessibilityTrusted { Permissions.requestAccessibility() }
        if !Permissions.inputMonitoringGranted { Permissions.requestInputMonitoring() }
        Task { _ = await Permissions.requestMicrophone() }

        hotkeys = HotkeyListener()
        hotkeys.bindings = store.settings.bindings
        hotkeys.isRecordingProvider = { [weak self] in self?.dictation.isRecording ?? false }
        hotkeys.onPTTStart = { [weak self] in self?.dictation.pttStart() }
        hotkeys.onPTTEnd = { [weak self] in self?.dictation.pttEnd() }
        hotkeys.onHandsFreeToggle = { [weak self] in self?.dictation.handsFreeToggle() }
        hotkeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .commandMode: self.dictation.commandModeToggle()
            case .cancelDictation: self.dictation.cancel()
            case .pasteLastTranscript: self.dictation.pasteLastTranscript()
            case .copyLastTranscript: self.dictation.copyLastTranscript()
            case .viewDiff: self.showActivity()
            case .openScratchpad: self.showScratchpad()
            case .pushToTalk, .handsFree: break // handled by Fn transitions
            }
        }

        if !hotkeys.start() {
            TextInjector.notify(title: "Murmur",
                body: "Global hotkeys need Accessibility & Input Monitoring permission. Grant them, then relaunch from the menu bar icon.")
        }

        // Pre-download speech model assets so first dictation is instant.
        let locale = Locale(identifier: store.settings.defaultLanguage)
        Task { try? await AudioTranscriber.ensureAssets(locale: locale) }

        // If the menu bar is so full that our icon lands behind the notch,
        // the app looks like it never opened. Give it a visible surface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.statusController.isHiddenByNotch else { return }
            TextInjector.notify(title: "Murmur is running",
                body: "Its menu bar icon is hidden behind the notch. Remove or ⌘-drag other menu bar icons to make room. Hold Fn to dictate — dictation works regardless.")
            self.showSettings()
        }
    }

    /// Opening Murmur.app while it's already running lands here: always show
    /// a window so "the app is not opening" can't happen silently.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMain(.home)
        return true
    }

    func showMain(_ section: MainSection) {
        if mainWindow == nil {
            let model = MainModel(store: store, dictation: dictation) { [weak self] in
                guard let self else { return }
                self.hotkeys.bindings = self.store.settings.bindings
            }
            mainModel = model
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Murmur"
            // Theme is a fixed light palette; without this, dark mode renders
            // semantic colors (TextField text, placeholders) white-on-white.
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(Theme.canvas)
            window.contentView = NSHostingView(rootView: MainView(model: model))
            window.center()
            mainWindow = window
        }
        mainModel?.section = section
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showSettings() { showMain(.settings) }
    func showScratchpad() { showMain(.scratchpad) }
    func showActivity() { showMain(.home) }
}
