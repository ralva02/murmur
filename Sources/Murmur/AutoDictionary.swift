import ApplicationServices
import Foundation
import MurmurCore

/// Auto-add-to-dictionary (spec §7.1): after inserting a transcript, re-read
/// the same field a little later and learn any spellings the user corrected.
/// Reads ONLY the field Murmur itself pasted into, and only while the
/// Personalization toggle is on.
@MainActor
final class AutoDictionaryMonitor {

    private let store: AppStore
    private var watchTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    /// Checks the field twice (users fix typos quickly or not at all).
    private let checkDelays: [Duration] = [.seconds(8), .seconds(20)]

    func watch(insertedText: String) {
        guard store.settings.autoAddDictionary else { return }
        guard let element = ContextReader.focusedElement() else { return }

        watchTask?.cancel()
        watchTask = Task { [weak self] in
            for delay in self?.checkDelays ?? [] {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                if self.check(element: element, insertedText: insertedText) { return }
            }
        }
    }

    /// Returns true when corrections were found (monitoring can stop).
    private func check(element: AXUIElement, insertedText: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let current = value as? String, !current.isEmpty
        else { return false }

        let known = store.dictionary.map(\.term)
        let corrections = CorrectionDetector.corrections(
            inserted: insertedText, current: current, knownTerms: known)
        guard !corrections.isEmpty else { return false }

        for term in corrections {
            store.dictionary.append(DictionaryEntry(term: term))
        }
        store.saveDictionary()
        Diag.dictation.notice("auto-added to dictionary: \(corrections.joined(separator: ", "), privacy: .public)")
        TextInjector.notify(title: "Added to dictionary",
            body: corrections.map { "“\($0)”" }.joined(separator: ", ")
                + " — Murmur will spell it this way from now on.")
        return true
    }
}
