import Foundation
import Testing
@testable import MurmurCore

private func tempTasksRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("murmur-tasks-tests-\(UUID().uuidString)")
}

@Test func tasksAddPartitionToggleDelete() throws {
    let root = tempTasksRoot()
    let store = TasksStore(rootDirectory: root)
    let rid = UUID()
    store.add([
        MurmurTask(title: "A", assignee: "Sue", recordingID: rid, recordingTitle: "Rec"),
        MurmurTask(title: "B", assignee: "Bob", recordingID: rid, recordingTitle: "Rec"),
    ])
    #expect(store.open.count == 2)
    #expect(store.done.isEmpty)

    let a = store.tasks.first { $0.title == "A" }!
    store.toggleDone(id: a.id)
    #expect(store.open.count == 1)
    #expect(store.done.count == 1)

    let reloaded = TasksStore(rootDirectory: root)
    #expect(reloaded.tasks.count == 2)
    #expect(reloaded.done.count == 1)

    store.delete(id: a.id)
    #expect(store.tasks.count == 1)
}

@Test func deleteTasksForRecording() throws {
    let store = TasksStore(rootDirectory: tempTasksRoot())
    let keep = UUID(); let drop = UUID()
    store.add([
        MurmurTask(title: "keep", assignee: "x", recordingID: keep, recordingTitle: "K"),
        MurmurTask(title: "drop", assignee: "x", recordingID: drop, recordingTitle: "D"),
    ])
    store.deleteTasks(forRecording: drop)
    #expect(store.tasks.map(\.title) == ["keep"])
}

@Test func productionPathTasksStoreTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        _ = TasksStore()
    }
}
