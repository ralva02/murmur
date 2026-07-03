import Foundation

public struct MurmurTask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var assignee: String
    public var done: Bool
    public var recordingID: UUID
    public var recordingTitle: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(), title: String, assignee: String, done: Bool = false,
        recordingID: UUID, recordingTitle: String, createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.done = done
        self.recordingID = recordingID
        self.recordingTitle = recordingTitle
        self.createdAt = createdAt
    }
}

/// Flat global to-do list extracted from recordings. Single tasks.json under
/// Application Support/Murmur; same test-guard as the other stores.
public final class TasksStore: @unchecked Sendable {

    private let fileURL: URL
    public private(set) var tasks: [MurmurTask] = []

    public init(rootDirectory: URL? = nil) {
        let root = rootDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur")
        let isDefault = rootDirectory == nil
        precondition(
            !(AppStore.isRunningUnderTestHarness && isDefault),
            "TasksStore: refusing to touch the real tasks file from a test run — pass an explicit temp path")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("tasks.json")
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([MurmurTask].self, from: data) {
            tasks = loaded
        }
    }

    public var open: [MurmurTask] { tasks.filter { !$0.done }.sorted { $0.createdAt > $1.createdAt } }
    public var done: [MurmurTask] { tasks.filter { $0.done }.sorted { $0.createdAt > $1.createdAt } }

    public func add(_ newTasks: [MurmurTask]) {
        tasks.append(contentsOf: newTasks)
        save()
    }

    public func toggleDone(id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        save()
    }

    public func delete(id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    public func deleteTasks(forRecording recordingID: UUID) {
        tasks.removeAll { $0.recordingID == recordingID }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
