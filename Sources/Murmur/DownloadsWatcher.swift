import Foundation
import UserNotifications

/// Watches ~/Downloads for new audio files (AirDropped Plaud exports) and
/// offers a confirm-to-import notification. Never imports silently.
@MainActor
final class DownloadsWatcher {

    nonisolated static let categoryID = "MURMUR_IMPORT"
    nonisolated static let importAction = "MURMUR_IMPORT_ACTION"

    private let directory = FileManager.default
        .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var known: Set<String> = []
    private let extensions: Set<String> = ["wav", "mp3", "m4a"]

    func start() {
        guard source == nil else { return }
        registerCategory()
        known = Set(currentAudioFiles())
        descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scan() }
        src.setCancelHandler { [descriptor = self.descriptor] in close(descriptor) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func currentAudioFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    private func scan() {
        let files = currentAudioFiles()
        for name in files where !known.contains(name) {
            known.insert(name)
            let url = directory.appendingPathComponent(name)
            // Give AirDrop a moment to finish writing before offering.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.offerImport(url)
            }
        }
    }

    private func offerImport(_ url: URL) {
        Diag.app.notice("downloads watcher: offering import of \(url.lastPathComponent, privacy: .public)")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Diag.app.notice("downloads watcher: notification auth granted=\(granted)")
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Import into Murmur?"
            content.body = url.lastPathComponent
            content.categoryIdentifier = Self.categoryID
            content.userInfo = ["path": url.path]
            center.add(UNNotificationRequest(
                identifier: "import-\(url.lastPathComponent)", content: content, trigger: nil))
        }
    }

    private func registerCategory() {
        let action = UNNotificationAction(
            identifier: Self.importAction, title: "Import", options: [])
        let category = UNNotificationCategory(
            identifier: Self.categoryID, actions: [action], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
