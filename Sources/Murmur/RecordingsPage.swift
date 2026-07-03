import AppKit
@preconcurrency import AVFAudio
import SwiftUI
import UniformTypeIdentifiers
import MurmurCore

@MainActor @Observable
final class RecordingsModel {
    let recordingsStore: RecordingsStore
    let pipeline: RecordingPipeline
    let appStore: AppStore
    let recorder = LongFormRecorder()
    var recordings: [Recording] = []
    var selectedID: UUID?
    var progress: [UUID: Double] = [:]

    init(recordingsStore: RecordingsStore, pipeline: RecordingPipeline, appStore: AppStore) {
        self.recordingsStore = recordingsStore
        self.pipeline = pipeline
        self.appStore = appStore
        self.recordings = recordingsStore.recordings
        pipeline.onChange = { [weak self] in
            guard let self else { return }
            self.recordings = self.recordingsStore.recordings
            self.progress = self.pipeline.progress
        }
        recorder.onStateChange = { [weak self] in
            guard let self else { return }
            self.recordings = self.recordingsStore.recordings
        }
    }

    var isRecording: Bool { recorder.isRecording }

    func toggleRecording() {
        if recorder.isRecording {
            Task {
                if let result = try? await recorder.stop() {
                    addInAppRecording(url: result.url, duration: result.duration, micOnly: result.micOnly)
                }
            }
        } else {
            try? recorder.start()
        }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls where ["wav", "mp3", "m4a"].contains(url.pathExtension.lowercased()) {
            let duration = (try? AVAudioFile(forReading: url)).map {
                Double($0.length) / $0.processingFormat.sampleRate
            } ?? 0
            if let rec = try? recordingsStore.create(
                importingAudioFrom: url,
                source: .imported(originalFilename: url.lastPathComponent),
                title: url.deletingPathExtension().lastPathComponent,
                duration: duration,
                language: appStore.settings.defaultLanguage,
                template: .auto) {
                recordings = recordingsStore.recordings
                pipeline.process(rec.id)
            }
        }
    }

    func addInAppRecording(url: URL, duration: TimeInterval, micOnly: Bool) {
        guard var rec = try? recordingsStore.create(
            importingAudioFrom: url, source: .inApp,
            title: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
            duration: duration,
            language: appStore.settings.defaultLanguage, template: .auto) else { return }
        rec.micOnly = micOnly
        recordingsStore.update(rec)
        recordings = recordingsStore.recordings
        pipeline.process(rec.id)
    }

    func retry(_ id: UUID) { pipeline.process(id) }

    func delete(_ id: UUID) {
        recordingsStore.delete(id: id)
        recordings = recordingsStore.recordings
        if selectedID == id { selectedID = nil }
    }

    func rename(_ id: UUID, to title: String) {
        guard var rec = recordings.first(where: { $0.id == id }) else { return }
        rec.title = title
        recordingsStore.update(rec)
        recordings = recordingsStore.recordings
    }
}

struct RecordingsPage: View {
    @Bindable var model: RecordingsModel

    var body: some View {
        Page(title: "Recordings") {
            HStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Button {
                        model.toggleRecording()
                    } label: {
                        if model.isRecording {
                            // Referencing timeline.date is what makes the
                            // TimelineView actually re-render each second.
                            Label("Stop \(elapsedLabel(at: timeline.date))", systemImage: "stop.circle.fill")
                        } else {
                            Label("Record", systemImage: "record.circle")
                        }
                    }
                    .buttonStyle(PrimaryPillButtonStyle())
                }
                Button("Import…") { openImportPanel() }
                    .buttonStyle(GhostButtonStyle())
            }
        } content: {
            if model.recordings.isEmpty {
                emptyState
            } else {
                ForEach(model.recordings) { recording in
                    RecordingRow(model: model, recording: recording,
                                 expanded: model.selectedID == recording.id)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.importFiles([url]) } }
                }
            }
            return true
        }
    }

    private func elapsedLabel(at date: Date) -> String {
        guard let started = model.recorder.startedAt else { return "" }
        let s = Int(date.timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No recordings yet")
                .font(Theme.serif(22))
                .foregroundStyle(Theme.ink)
            Text("Record a meeting with the ● button, drag audio files here, or export from the Plaud app (MP3/WAV) and import. Transcription runs on this Mac.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(24)
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .mp3, .mpeg4Audio]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.importFiles(panel.urls)
        }
    }
}

private struct RecordingRow: View {
    @Bindable var model: RecordingsModel
    let recording: Recording
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.selectedID = expanded ? nil : recording.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recording.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Text("\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(durationLabel)\(recording.micOnly ? " · mic only" : "")")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    statusBadge
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                RecordingDetail(model: model, recording: recording)
                    .padding([.horizontal, .bottom], 14)
            }
        }
        .card()
        .padding(.bottom, 8)
    }

    private var durationLabel: String {
        let total = Int(recording.duration)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    @ViewBuilder private var statusBadge: some View {
        switch recording.status {
        case .ready:
            Text("Ready").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
        case .transcribing:
            HStack(spacing: 6) {
                ProgressView(value: model.progress[recording.id] ?? 0)
                    .frame(width: 60)
                Text("Transcribing").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        case .transcribed:
            Text("Transcribed").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
        case .summarizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing").font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(_, let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 11)).foregroundStyle(Theme.inkSecondary)
                    .lineLimit(1).frame(maxWidth: 220)
                Button("Retry") { model.retry(recording.id) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

private struct RecordingDetail: View {
    @Bindable var model: RecordingsModel
    let recording: Recording
    @State private var player = PlayerModel()
    @State private var template: SummaryTemplate = .auto
    @State private var transcriptShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Editable title
            TextField("Title", text: Binding(
                get: { recording.title },
                set: { model.rename(recording.id, to: $0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)

            // Player
            HStack(spacing: 10) {
                Button {
                    player.toggle(url: model.recordingsStore.audioURL(for: recording))
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
                Slider(value: $player.position, in: 0...max(recording.duration, 1)) { editing in
                    if !editing { player.seek(to: player.position) }
                }
                Text(player.timeLabel(total: recording.duration))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }

            // Summarize controls
            HStack(spacing: 10) {
                Picker("", selection: $template) {
                    ForEach(SummaryTemplate.allCases, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button(model.recordingsStore.summary(for: recording.id) == nil ? "Summarize" : "Re-summarize") {
                    model.pipeline.resummarize(recording.id, template: template)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                .disabled(model.recordingsStore.transcript(for: recording.id) == nil)
                Spacer()
                if let summary = model.recordingsStore.summary(for: recording.id) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary, forType: .string)
                    }
                    .buttonStyle(GhostButtonStyle())
                    Button("Export…") { exportSummary(summary) }
                        .buttonStyle(GhostButtonStyle())
                }
                Button(role: .destructive) { confirmDelete() } label: { Text("Delete") }
                    .buttonStyle(GhostButtonStyle())
            }

            if let summary = model.recordingsStore.summary(for: recording.id) {
                summaryView(summary)
            }

            if let transcript = model.recordingsStore.transcript(for: recording.id) {
                DisclosureGroup("Transcript", isExpanded: $transcriptShown) {
                    Text(transcript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            }
        }
        .onAppear { template = recording.template }
        .onDisappear { player.stop() }
    }

    private func summaryView(_ markdown: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        return Text(attributed)
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func exportSummary(_ summary: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.title + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            let doc = "# \(recording.title)\n\n_\(recording.createdAt.formatted())_\n\n" + summary
            try? Data(doc.utf8).write(to: url)
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete “\(recording.title)”?"
        alert.informativeText = "The audio, transcript, and summary will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.delete(recording.id)
        }
    }
}

/// Small AVAudioPlayer wrapper with scrubbing.
@MainActor @Observable
final class PlayerModel {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var position: TimeInterval = 0

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player?.url != url {
            player = try? AVAudioPlayer(contentsOf: url)
        }
        player?.currentTime = position
        player?.play()
        isPlaying = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.timer?.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        position = time
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        isPlaying = false
    }

    func timeLabel(total: TimeInterval) -> String {
        func fmt(_ t: TimeInterval) -> String {
            String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
        }
        return "\(fmt(position)) / \(fmt(total))"
    }
}
