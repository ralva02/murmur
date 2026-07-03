import SwiftUI
import MurmurCore

@MainActor @Observable
final class TasksModel {
    let store: TasksStore
    var tasks: [MurmurTask] = []
    /// Set by AppMain to jump to a recording when a task's link is tapped.
    var onOpenRecording: (UUID) -> Void = { _ in }

    init(store: TasksStore) {
        self.store = store
        tasks = store.tasks
    }

    func refresh() { tasks = store.tasks }
    func toggle(_ id: UUID) { store.toggleDone(id: id); refresh() }
    func delete(_ id: UUID) { store.delete(id: id); refresh() }
    var open: [MurmurTask] { store.open }
    var done: [MurmurTask] { store.done }
}

struct TasksPage: View {
    @Bindable var model: TasksModel

    var body: some View {
        Page(title: "Tasks") {
            EmptyView()
        } content: {
            if model.tasks.isEmpty {
                Text("Action items from your recordings show up here after you review them.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(24)
            } else {
                if !model.open.isEmpty {
                    sectionLabel("Open", model.open.count)
                    ForEach(model.open) { row($0) }
                }
                if !model.done.isEmpty {
                    sectionLabel("Done", model.done.count)
                    ForEach(model.done) { row($0) }
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private func sectionLabel(_ title: String, _ count: Int) -> some View {
        Text("\(title.uppercased())  \(count)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.inkTertiary)
            .kerning(0.8)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ task: MurmurTask) -> some View {
        HStack(spacing: 10) {
            Button { model.toggle(task.id) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? .green : Theme.inkTertiary)
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(task.done ? Theme.inkTertiary : Theme.ink)
                    .strikethrough(task.done)
                Button {
                    model.onOpenRecording(task.recordingID)
                } label: {
                    Text(task.recordingTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.violet)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if task.assignee != "Unassigned" {
                Text(task.assignee)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.sidebarSelection, in: Capsule())
            }
            Button { model.delete(task.id) } label: {
                Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(Theme.inkTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .card()
        .padding(.bottom, 6)
    }
}

/// Draft-then-confirm sheet: edit title/assignee, keep/drop, then commit.
struct TaskReviewSheet: View {
    let recording: Recording
    let tasksStore: TasksStore
    let recordingsStore: RecordingsStore
    let onClose: () -> Void

    @State private var drafts: [Draft]

    struct Draft: Identifiable {
        let id = UUID()
        var title: String
        var assignee: String
        var keep: Bool
    }

    init(recording: Recording, tasksStore: TasksStore, recordingsStore: RecordingsStore, onClose: @escaping () -> Void) {
        self.recording = recording
        self.tasksStore = tasksStore
        self.recordingsStore = recordingsStore
        self.onClose = onClose
        _drafts = State(initialValue: recording.pendingTasks.map {
            Draft(title: $0.title, assignee: $0.assignee, keep: true)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review tasks")
                .font(Theme.serif(20))
                .foregroundStyle(Theme.ink)
            Text("The LLM guessed the owners — fix any that are wrong before adding.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($drafts) { $draft in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $draft.keep).labelsHidden().controlSize(.small)
                            TextField("Task", text: $draft.title)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TextField("Assignee", text: $draft.assignee)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .frame(width: 120)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Theme.canvas, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1))
                        }
                        .opacity(draft.keep ? 1 : 0.45)
                        .padding(10)
                        .card()
                    }
                }
            }
            .frame(maxHeight: 320)

            HStack {
                Button("Dismiss") { clearPending(); onClose() }
                    .buttonStyle(GhostButtonStyle())
                Spacer()
                Button("Add to Tasks") { commit(); onClose() }
                    .buttonStyle(PrimaryPillButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Theme.card)
    }

    private func commit() {
        let kept = drafts.filter { $0.keep && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        let tasks = kept.map {
            MurmurTask(title: $0.title, assignee: $0.assignee.isEmpty ? "Unassigned" : $0.assignee,
                       recordingID: recording.id, recordingTitle: recording.title)
        }
        tasksStore.add(tasks)
        clearPending()
    }

    private func clearPending() {
        var rec = recording
        rec.pendingTasks = []
        recordingsStore.update(rec)
    }
}
