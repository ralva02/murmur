import Foundation
import Testing
@testable import MurmurCore

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("murmur-rec-tests-\(UUID().uuidString)")
}

private func makeAudioFixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fixture-\(UUID().uuidString).wav")
    try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)   // content irrelevant to the store
    return url
}

@Test func createCopiesAudioAndPersists() throws {
    let root = tempRoot()
    let store = RecordingsStore(rootDirectory: root)
    let audio = try makeAudioFixture()

    let rec = try store.create(
        importingAudioFrom: audio,
        source: .imported(originalFilename: "meeting.wav"),
        title: "Team sync", duration: 61.5,
        language: "en-US", template: .auto)

    #expect(rec.status == .ready)
    #expect(FileManager.default.fileExists(atPath: audio.path))          // copied, not moved
    #expect(FileManager.default.fileExists(atPath: store.audioURL(for: rec).path))

    let reloaded = RecordingsStore(rootDirectory: root)
    #expect(reloaded.recordings.count == 1)
    #expect(reloaded.recordings[0].title == "Team sync")
}

@Test func transcriptAndSummaryRoundTrip() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    let rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .meeting)

    store.saveTranscript("hello world", for: rec.id)
    store.saveSummary("## Summary\n- hi", for: rec.id)
    #expect(store.transcript(for: rec.id) == "hello world")
    #expect(store.summary(for: rec.id) == "## Summary\n- hi")
}

@Test func statusUpdatesPersist() throws {
    let root = tempRoot()
    let store = RecordingsStore(rootDirectory: root)
    var rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .auto)

    rec.status = .failed(stage: .transcription, message: "boom")
    store.update(rec)
    let reloaded = RecordingsStore(rootDirectory: root)
    #expect(reloaded.recordings[0].status == .failed(stage: .transcription, message: "boom"))
}

@Test func deleteRemovesFolder() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    let rec = try store.create(
        importingAudioFrom: makeAudioFixture(), source: .inApp,
        title: "r", duration: 1, language: "en-US", template: .auto)
    let dir = store.directory(for: rec.id)
    store.delete(id: rec.id)
    #expect(store.recordings.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: dir.path))
}

@Test func newestFirstOrdering() throws {
    let store = RecordingsStore(rootDirectory: tempRoot())
    _ = try store.create(importingAudioFrom: makeAudioFixture(), source: .inApp,
                         title: "old", duration: 1, language: "en-US", template: .auto)
    _ = try store.create(importingAudioFrom: makeAudioFixture(), source: .inApp,
                         title: "new", duration: 1, language: "en-US", template: .auto)
    #expect(store.recordings.first?.title == "new")
}

// Same regression guard as AppStore (2026-07-03 data-loss postmortem):
// production-path construction from a test process must trap.
@Test func productionPathRecordingsStoreTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        _ = RecordingsStore()
    }
}
