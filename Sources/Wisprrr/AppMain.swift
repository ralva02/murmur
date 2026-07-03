import AppKit
import SwiftUI
import WisprrrCore

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
    private var settingsWindow: NSWindow?
    private var activityWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        dictation = DictationController(store: store)

        statusController = StatusItemController(
            dictation: dictation,
            store: store,
            openSettings: { [weak self] in self?.showSettings() },
            openActivity: { [weak self] in self?.showActivity() })

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
            case .viewDiff: self.showActivity()
            case .pushToTalk, .handsFree: break // handled by Fn transitions
            }
        }

        if !hotkeys.start() {
            TextInjector.notify(title: "Wisprrr",
                body: "Global hotkeys need Accessibility & Input Monitoring permission. Grant them, then relaunch from the menu bar icon.")
        }

        // Pre-download speech model assets so first dictation is instant.
        let locale = Locale(identifier: store.settings.defaultLanguage)
        Task { try? await AudioTranscriber.ensureAssets(locale: locale) }

        // If the menu bar is so full that our icon lands behind the notch,
        // the app looks like it never opened. Give it a visible surface.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.statusController.isHiddenByNotch else { return }
            TextInjector.notify(title: "Wisprrr is running",
                body: "Its menu bar icon is hidden behind the notch. Remove or ⌘-drag other menu bar icons to make room. Hold Fn to dictate — dictation works regardless.")
            self.showSettings()
        }
    }

    /// Opening Wisprrr.app while it's already running lands here: always show
    /// a window so "the app is not opening" can't happen silently.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Wisprrr Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView(store: store, onBindingsChanged: { [weak self] in
                    guard let self else { return }
                    self.hotkeys.bindings = self.store.settings.bindings
                }))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showActivity() {
        if activityWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "Wisprrr — Recent Activity"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ActivityView(store: store, dictation: dictation))
            window.center()
            activityWindow = window
        }
        activityWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
