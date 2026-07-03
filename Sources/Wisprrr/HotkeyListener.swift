import AppKit
import CoreGraphics
import WisprrrCore

/// Global hotkey handling via a listen-only CGEventTap (spec §4.1, §4.2):
/// - Hold Fn → push-to-talk (start on press, stop on release).
/// - Quick double-tap Fn → hands-free toggle.
/// - Rebindable key combos for command mode, cancel, paste-last, view-diff.
@MainActor
final class HotkeyListener {

    var onPTTStart: (() -> Void)?
    var onPTTEnd: (() -> Void)?
    var onHandsFreeToggle: (() -> Void)?
    var onAction: ((BindableAction) -> Void)?
    /// Escape cancels only while this returns true (spec §4.2 cancel binding).
    var isRecordingProvider: (() -> Bool)?

    var bindings: [HotkeyBinding] = HotkeyBinding.defaults

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var fnIsDown = false
    private var fnPressStartedAt: TimeInterval = 0
    private var lastFnTapEndedAt: TimeInterval = 0
    private var pttActive = false
    private var pendingHoldWork: DispatchWorkItem?

    /// Releases within this window count as a tap rather than a hold.
    private let tapMaxDuration: TimeInterval = 0.25
    /// Two taps within this window toggle hands-free.
    private let doubleTapWindow: TimeInterval = 0.40

    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let listener = Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
            // The tap fires on our dedicated runloop thread; state is only
            // touched on the main actor.
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            DispatchQueue.main.async {
                listener.handle(type: type, flags: flags, keyCode: keyCode)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Diag.hotkeys.error("event tap creation FAILED (needs Accessibility or Input Monitoring)")
            return false
        }
        Diag.hotkeys.notice("event tap created")

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    /// Re-enables the tap if macOS disabled it (timeout/user input protection).
    func reviveIfNeeded() {
        if let tap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func handle(type: CGEventType, flags: CGEventFlags, keyCode: Int64) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reviveIfNeeded()
            return
        }

        if type == .flagsChanged {
            handleFnTransition(isDown: flags.contains(.maskSecondaryFn))
            return
        }

        if type == .keyDown {
            let relevantMask: UInt64 = (CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskAlternate.rawValue
                | CGEventFlags.maskControl.rawValue
                | CGEventFlags.maskShift.rawValue)
            let activeMods = flags.rawValue & relevantMask
            for binding in bindings {
                guard let bindingKey = binding.keyCode, bindingKey == keyCode,
                      binding.modifiers == activeMods else { continue }
                if binding.action == .cancelDictation, isRecordingProvider?() != true { continue }
                onAction?(binding.action)
                return
            }
        }
    }

    private func handleFnTransition(isDown: Bool) {
        guard isDown != fnIsDown else { return }
        Diag.hotkeys.notice("fn \(isDown ? "pressed" : "released")")
        fnIsDown = isDown
        let now = ProcessInfo.processInfo.systemUptime

        if isDown {
            fnPressStartedAt = now
            // Push-to-talk begins only once the key has been held past the
            // tap threshold, so taps never spawn throwaway sessions.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.fnIsDown, !self.pttActive else { return }
                self.pttActive = true
                self.onPTTStart?()
            }
            pendingHoldWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + tapMaxDuration, execute: work)
        } else {
            pendingHoldWork?.cancel()
            pendingHoldWork = nil
            if pttActive {
                // End of a hold → finish push-to-talk.
                pttActive = false
                onPTTEnd?()
            } else if isRecordingProvider?() == true {
                // Single tap while hands-free recording → stop it.
                lastFnTapEndedAt = 0
                onHandsFreeToggle?()
            } else if now - lastFnTapEndedAt <= doubleTapWindow {
                // Double tap → start hands-free.
                lastFnTapEndedAt = 0
                onHandsFreeToggle?()
            } else {
                lastFnTapEndedAt = now
            }
        }
    }
}
