import AppKit
import ApplicationServices
@preconcurrency import AVFoundation

/// Permission checks and re-grant flows (spec §17: keep running when a
/// permission is revoked, surface a warning, allow re-grant without restart).
@MainActor
enum Permissions {

    static var accessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt once if not yet trusted.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    static func requestInputMonitoring() {
        CGRequestListenEventAccess()
    }

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static var allGranted: Bool {
        accessibilityTrusted && inputMonitoringGranted && microphoneGranted
    }

    static func openSystemSettings(anchor: String) {
        let url = "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func openAccessibilitySettings() { openSystemSettings(anchor: "Privacy_Accessibility") }
    static func openInputMonitoringSettings() { openSystemSettings(anchor: "Privacy_ListenEvent") }
    static func openMicrophoneSettings() { openSystemSettings(anchor: "Privacy_Microphone") }
}
