import Foundation
import Testing
@testable import WisprrrCore

@Test func settingsDefaultsRoundTrip() throws {
    let s = Settings()
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(Settings.self, from: data)
    #expect(back.contextAwareness == true)
    #expect(back.cleanupModel == "gemma4:e4b")
}

@Test func appCategorization() {
    #expect(AppCategory.categorize(bundleId: "com.apple.mail") == .email)
    #expect(AppCategory.categorize(bundleId: "com.tinyspeck.slackmacgap") == .chat)
    #expect(AppCategory.categorize(bundleId: "com.microsoft.VSCode") == .code)
    #expect(AppCategory.categorize(bundleId: "com.unknown.thing") == .other)
}
