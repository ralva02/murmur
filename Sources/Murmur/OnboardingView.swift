import AppKit
import Combine   // Timer.publish for the 1 s permission polls
import SwiftUI
import MurmurCore

enum OnboardingStep: Int, CaseIterable {
    case welcome, microphone, accessibility, inputMonitoring, cleanup, tryIt
}

/// First-run wizard. Owns the MainWindow content until finished; every step
/// is skippable — closing the window or skipping never blocks dictation.
struct OnboardingView: View {
    @Bindable var model: MainModel
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .padding(36)
        .background(Theme.canvas)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .microphone:
            PermissionStep(
                title: "Microphone",
                explanation: "Murmur records your voice only while you hold the dictation key. Audio never leaves this Mac.",
                isGranted: { Permissions.microphoneGranted },
                request: { Task { _ = await Permissions.requestMicrophone() } },
                openSettings: Permissions.openMicrophoneSettings)
        case .accessibility:
            PermissionStep(
                title: "Accessibility",
                explanation: "Lets Murmur type the polished text into whatever app you're using.",
                isGranted: { Permissions.accessibilityTrusted },
                request: Permissions.requestAccessibility,
                openSettings: Permissions.openAccessibilitySettings)
        case .inputMonitoring:
            PermissionStep(
                title: "Input Monitoring",
                explanation: "Lets Murmur notice when you hold Fn to dictate. It listens for that key only.",
                isGranted: { Permissions.inputMonitoringGranted },
                request: Permissions.requestInputMonitoring,
                openSettings: Permissions.openInputMonitoringSettings)
        case .cleanup: CleanupStep(model: model)
        case .tryIt: TryItStep()
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }.buttonStyle(GhostButtonStyle())
            }
            Spacer()
            Text("\(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
            Spacer()
            Button(step == .tryIt ? "Finish" : "Continue") {
                if step == .tryIt { finish() } else { move(1) }
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
            model.onPermissionsChanged()   // re-arm hotkeys as grants land
        }
    }

    private func finish() {
        model.store.settings.onboardingCompleted = true
        model.settingsModel.settings.onboardingCompleted = true
        model.onPermissionsChanged()
        withAnimation(.easeInOut(duration: 0.25)) { model.showOnboarding = false }
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    @State private var moveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(nsImage: MurmurIcon.idle)
            Text("Speak it. Murmur types it.")
                .font(Theme.serif(34))
                .foregroundStyle(Theme.ink)
            Text("Hold Fn and talk — polished text lands wherever your cursor is. Everything runs on this Mac; nothing leaves it. The next steps set up the three permissions dictation needs.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            if AppRelocator.isTranslocated {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Murmur is running from a temporary location, which makes macOS forget its permissions. Move it to Applications first.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                    Button("Move to Applications and Relaunch") {
                        if !AppRelocator.moveToApplicationsAndRelaunch() { moveFailed = true }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    if moveFailed {
                        Text("Couldn't move automatically — quit Murmur, drag it to Applications in Finder, and open it again.")
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(Theme.violet.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Gatekeeper app translocation runs quarantined apps from a randomized
/// read-only path; TCC grants don't stick there. Detect and fix.
@MainActor
enum AppRelocator {
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Copies the bundle to /Applications, strips quarantine (the user already
    /// approved the app by opening it), relaunches from there. Returns false
    /// if any step fails so the UI can show manual instructions.
    static func moveToApplicationsAndRelaunch() -> Bool {
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let dest = URL(fileURLWithPath: "/Applications/Murmur.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
        } catch { return false }

        let strip = Process()
        strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        strip.arguments = ["-dr", "com.apple.quarantine", dest.path]
        try? strip.run()
        strip.waitUntilExit()

        NSWorkspace.shared.openApplication(
            at: dest, configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        return true
    }
}

// MARK: - Permission step (shared by mic / AX / input monitoring)

private struct PermissionStep: View {
    let title: String
    let explanation: String
    let isGranted: () -> Bool
    let request: () -> Void
    let openSettings: () -> Void

    @State private var granted = false
    @State private var requested = false
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HStack(spacing: 10) {
                Circle()
                    .fill(granted ? Color.green : Theme.inkTertiary)
                    .frame(width: 12, height: 12)
                Text(title)
                    .font(Theme.serif(30))
                    .foregroundStyle(Theme.ink)
            }
            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                HStack(spacing: 12) {
                    Button("Grant Access") {
                        requested = true
                        request()
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                    if requested {
                        Button("Open System Settings") { openSettings() }
                            .buttonStyle(GhostButtonStyle())
                    }
                }
                Text("You can skip this and grant it later — Murmur keeps working either way.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { granted = isGranted() }
        .onReceive(tick) { _ in granted = isGranted() }
    }
}

// MARK: - Cleanup engine

private struct CleanupStep: View {
    @Bindable var model: MainModel
    @State private var aiStatus = AppleIntelligenceStatus.current()
    @State private var showOllama = false
    @State private var ollamaAlive = false
    @State private var pullProgress: Double?
    @State private var pullStatus: String?
    @State private var pullError: String?
    @State private var pullTask: Task<Void, Never>?
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Polished, not just transcribed")
                .font(Theme.serif(30))
                .foregroundStyle(Theme.ink)
            Text("A local model removes filler words, fixes punctuation, and resolves \"wait, no…\" corrections. Nothing leaves this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 480, alignment: .leading)

            engineRow(
                selected: model.settingsModel.settings.cleanupEngine == .appleIntelligence,
                title: "Apple Intelligence",
                subtitle: aiStatus.explanation,
                enabled: aiStatus == .ready
            ) { model.settingsModel.settings.cleanupEngine = .appleIntelligence }

            engineRow(
                selected: model.settingsModel.settings.cleanupEngine == .ollama,
                title: "Ollama (best quality)",
                subtitle: ollamaAlive
                    ? "Ollama is running."
                    : "Runs larger models locally. Install it from ollama.com, then download a model here.",
                enabled: ollamaAlive
            ) { model.settingsModel.settings.cleanupEngine = .ollama }

            DisclosureGroup("Set up Ollama", isExpanded: $showOllama) {
                VStack(alignment: .leading, spacing: 10) {
                    if !ollamaAlive {
                        HStack(spacing: 10) {
                            Button("Get Ollama") {
                                NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!)
                            }
                            .buttonStyle(GhostButtonStyle())
                            Text("Waiting for Ollama to start…")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    } else if let progress = pullProgress {
                        HStack(spacing: 10) {
                            ProgressView(value: progress).tint(Theme.violet).frame(width: 220)
                            Text(pullStatus ?? "downloading…")
                                .font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
                            Button("Cancel") { pullTask?.cancel() }.buttonStyle(GhostButtonStyle())
                        }
                    } else {
                        Button("Download \(model.settingsModel.settings.cleanupModel)") { startPull() }
                            .buttonStyle(PrimaryPillButtonStyle())
                    }
                    if let pullError {
                        HStack(spacing: 10) {
                            Text(pullError).font(.system(size: 12)).foregroundStyle(.red)
                            Button("Retry") { startPull() }.buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                .padding(.top, 8)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: 480, alignment: .leading)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { probe() }
        .onReceive(tick) { _ in probe() }
        .onDisappear { pullTask?.cancel() }
    }

    private func probe() {
        aiStatus = AppleIntelligenceStatus.current()
        guard let url = URL(string: model.settingsModel.settings.ollamaURL) else { return }
        Task {
            let alive = await OllamaClient(baseURL: url).isAlive()
            await MainActor.run { ollamaAlive = alive }
        }
    }

    private func startPull() {
        guard let url = URL(string: model.settingsModel.settings.ollamaURL) else { return }
        let modelName = model.settingsModel.settings.cleanupModel
        pullError = nil
        pullProgress = 0
        pullTask = Task {
            do {
                try await OllamaClient(baseURL: url).pull(model: modelName) { event in
                    Task { @MainActor in
                        if let f = event.fraction { pullProgress = f }
                        pullStatus = event.status
                        if event.isSuccess {
                            pullProgress = nil
                            model.settingsModel.settings.cleanupEngine = .ollama
                        }
                    }
                }
                await MainActor.run { pullProgress = nil }
            } catch is CancellationError {
                await MainActor.run { pullProgress = nil }
            } catch {
                await MainActor.run {
                    pullProgress = nil
                    pullError = error.localizedDescription
                }
            }
        }
    }

    private func engineRow(
        selected: Bool, title: String, subtitle: String,
        enabled: Bool, choose: @escaping () -> Void
    ) -> some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.violet : Theme.inkTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: 480, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.violet : Theme.cardBorder, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled && !selected)
        .opacity(enabled || selected ? 1 : 0.55)
    }
}

// MARK: - Try it

private struct TryItStep: View {
    @State private var scratch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("Try it")
                .font(Theme.serif(30))
                .foregroundStyle(Theme.ink)
            Text("Click into the field below, hold **Fn**, and say something like \"um so let's meet tuesday, wait no, friday\". Release Fn and watch the polished version land.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: 480, alignment: .leading)
            TextEditor(text: $scratch)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxWidth: 480, minHeight: 120, maxHeight: 160)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 1))
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
