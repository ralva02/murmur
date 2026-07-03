import Foundation
import Testing
@testable import MurmurCore

@Test func settingsDefaultsRoundTrip() throws {
    let s = Settings()
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(Settings.self, from: data)
    #expect(back.contextAwareness == true)
    #expect(back.cleanupModel == "gemma4:e4b")
}

@Test func freshSettingsDefaultToAppleIntelligenceAndOnboardingPending() {
    let s = Settings()
    #expect(s.cleanupEngine == .appleIntelligence)
    #expect(s.onboardingCompleted == false)
}

@Test func legacySettingsFileKeepsOllamaAndSkipsOnboarding() throws {
    // A settings.json written before these fields existed.
    let json = """
    {"contextAwareness":true,"autoAddDictionary":false,"defaultLanguage":"en-US",
     "cleanupEnabled":true,"cleanupModel":"gemma4:e4b","ollamaURL":"http://127.0.0.1:11434",
     "pressEnterEnabled":true,"historyEnabled":true,"bindings":[]}
    """
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.cleanupEngine == .ollama)
    #expect(s.onboardingCompleted == true)
}

@Test func cleanupEngineAndOnboardingRoundTrip() throws {
    var s = Settings()
    s.cleanupEngine = .ollama
    s.onboardingCompleted = true
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}

@Test func summarySettingsDefaultsAndMigration() throws {
    let fresh = Settings()
    #expect(fresh.summaryEngine == .ollama)
    #expect(fresh.claudeModel == "claude-opus-4-8")
    #expect(fresh.downloadsWatcherEnabled == false)

    var s = Settings()
    s.summaryEngine = .claude
    s.claudeModel = "claude-sonnet-5"
    s.downloadsWatcherEnabled = true
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
}

@Test func lmStudioSettingsDefaultsAndRoundTrip() throws {
    let fresh = Settings()
    #expect(fresh.lmStudioURL == "http://localhost:1234/v1")
    #expect(fresh.lmStudioModel == "")
    var s = Settings()
    s.summaryEngine = .lmStudio
    s.lmStudioModel = "qwen-mlx"
    let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
    #expect(back == s)
    #expect(back.summaryEngine == .lmStudio)
}

@Test func appCategorization() {
    #expect(AppCategory.categorize(bundleId: "com.apple.mail") == .email)
    #expect(AppCategory.categorize(bundleId: "com.tinyspeck.slackmacgap") == .chat)
    #expect(AppCategory.categorize(bundleId: "com.microsoft.VSCode") == .code)
    #expect(AppCategory.categorize(bundleId: "com.unknown.thing") == .other)
}
