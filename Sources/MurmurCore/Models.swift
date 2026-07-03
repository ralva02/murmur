import Foundation

// MARK: - App categories (spec §6, §7.3)

public enum AppCategory: String, Codable, Sendable, CaseIterable, Equatable {
    case email, chat, docs, notes, code, browser, terminal, other

    private static let table: [(keyword: String, category: AppCategory)] = [
        ("mail", .email), ("outlook", .email), ("spark", .email), ("mimestream", .email),
        ("slack", .chat), ("messages", .chat), ("discord", .chat), ("telegram", .chat),
        ("whatsapp", .chat), ("signal", .chat), ("mattermost", .chat),
        ("word", .docs), ("pages", .docs), ("googledocs", .docs), ("libreoffice", .docs),
        ("notes", .notes), ("notion", .notes), ("obsidian", .notes), ("bear", .notes),
        ("craft", .notes), ("evernote", .notes),
        ("xcode", .code), ("vscode", .code), ("cursor", .code), ("windsurf", .code),
        ("jetbrains", .code), ("intellij", .code), ("sublimetext", .code), ("zed", .code),
        ("terminal", .terminal), ("iterm", .terminal), ("ghostty", .terminal),
        ("warp", .terminal), ("alacritty", .terminal), ("kitty", .terminal),
        ("safari", .browser), ("chrome", .browser), ("arc", .browser),
        ("firefox", .browser), ("edgemac", .browser), ("brave", .browser),
    ]

    public static func categorize(bundleId: String?) -> AppCategory {
        guard let id = bundleId?.lowercased() else { return .other }
        for (keyword, category) in table where id.contains(keyword) {
            return category
        }
        return .other
    }
}

// MARK: - Rebindable shortcuts (spec §4.2)

public enum BindableAction: String, Codable, Sendable, CaseIterable, Equatable {
    case pushToTalk, handsFree, commandMode, cancelDictation, pasteLastTranscript, viewDiff
    case copyLastTranscript, openScratchpad
}

public struct HotkeyBinding: Codable, Sendable, Equatable {
    public var action: BindableAction
    /// Virtual key code; nil means the Fn/Globe modifier itself.
    public var keyCode: Int64?
    /// CGEventFlags raw value that must be held.
    public var modifiers: UInt64

    public init(action: BindableAction, keyCode: Int64?, modifiers: UInt64) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaults: [HotkeyBinding] = [
        HotkeyBinding(action: .pushToTalk, keyCode: nil, modifiers: 0),        // hold Fn
        HotkeyBinding(action: .handsFree, keyCode: nil, modifiers: 0),         // double-tap Fn
        HotkeyBinding(action: .commandMode, keyCode: 8, modifiers: 0x0004_0000 | 0x0008_0000), // Ctrl+Opt+C
        HotkeyBinding(action: .cancelDictation, keyCode: 53, modifiers: 0),    // Esc while recording
        HotkeyBinding(action: .pasteLastTranscript, keyCode: 9, modifiers: 0x0004_0000 | 0x0008_0000), // Ctrl+Opt+V
        HotkeyBinding(action: .viewDiff, keyCode: 2, modifiers: 0x0004_0000 | 0x0008_0000),    // Ctrl+Opt+D
        HotkeyBinding(action: .copyLastTranscript, keyCode: 7, modifiers: 0x0004_0000 | 0x0008_0000), // Ctrl+Opt+X
        HotkeyBinding(action: .openScratchpad, keyCode: 45, modifiers: 0x0004_0000 | 0x0008_0000),    // Ctrl+Opt+N
    ]
}

// MARK: - Settings (spec §16)

public enum CleanupEngine: String, Codable, Sendable, Equatable {
    case appleIntelligence, ollama
}

public enum SummaryEngine: String, Codable, Sendable, Equatable {
    case ollama, claude
}

public struct Settings: Codable, Sendable, Equatable {
    public var contextAwareness: Bool
    public var autoAddDictionary: Bool
    public var defaultLanguage: String
    /// Optional: translate final output into this language (e.g. "Spanish").
    /// Optional so settings saved before this field existed still decode.
    public var outputLanguage: String?
    public var cleanupEnabled: Bool
    /// Which LLM polishes transcripts. Fresh installs use the zero-setup
    /// Apple on-device model; files saved before this field existed decode
    /// to .ollama so existing installs keep their behavior.
    public var cleanupEngine: CleanupEngine
    public var cleanupModel: String
    public var ollamaURL: String
    public var pressEnterEnabled: Bool
    public var historyEnabled: Bool
    public var bindings: [HotkeyBinding]
    public var onboardingCompleted: Bool
    /// Long-form recording summaries: local Ollama by default, Claude opt-in.
    public var summaryEngine: SummaryEngine
    public var claudeModel: String
    public var downloadsWatcherEnabled: Bool

    public init(
        contextAwareness: Bool = true,
        autoAddDictionary: Bool = false,
        defaultLanguage: String = "en-US",
        cleanupEnabled: Bool = true,
        cleanupEngine: CleanupEngine = .appleIntelligence,
        cleanupModel: String = "gemma4:e4b",
        ollamaURL: String = "http://127.0.0.1:11434",
        pressEnterEnabled: Bool = true,
        historyEnabled: Bool = true,
        bindings: [HotkeyBinding] = HotkeyBinding.defaults,
        onboardingCompleted: Bool = false,
        summaryEngine: SummaryEngine = .ollama,
        claudeModel: String = "claude-opus-4-8",
        downloadsWatcherEnabled: Bool = false
    ) {
        self.contextAwareness = contextAwareness
        self.autoAddDictionary = autoAddDictionary
        self.defaultLanguage = defaultLanguage
        self.cleanupEnabled = cleanupEnabled
        self.cleanupEngine = cleanupEngine
        self.cleanupModel = cleanupModel
        self.ollamaURL = ollamaURL
        self.pressEnterEnabled = pressEnterEnabled
        self.historyEnabled = historyEnabled
        self.bindings = bindings
        self.onboardingCompleted = onboardingCompleted
        self.summaryEngine = summaryEngine
        self.claudeModel = claudeModel
        self.downloadsWatcherEnabled = downloadsWatcherEnabled
    }

    enum CodingKeys: String, CodingKey {
        case contextAwareness, autoAddDictionary, defaultLanguage, outputLanguage
        case cleanupEnabled, cleanupModel, ollamaURL, pressEnterEnabled
        case historyEnabled, bindings, cleanupEngine, onboardingCompleted
        case summaryEngine, claudeModel, downloadsWatcherEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextAwareness = try c.decode(Bool.self, forKey: .contextAwareness)
        autoAddDictionary = try c.decode(Bool.self, forKey: .autoAddDictionary)
        defaultLanguage = try c.decode(String.self, forKey: .defaultLanguage)
        outputLanguage = try c.decodeIfPresent(String.self, forKey: .outputLanguage)
        cleanupEnabled = try c.decode(Bool.self, forKey: .cleanupEnabled)
        cleanupModel = try c.decode(String.self, forKey: .cleanupModel)
        ollamaURL = try c.decode(String.self, forKey: .ollamaURL)
        pressEnterEnabled = try c.decode(Bool.self, forKey: .pressEnterEnabled)
        historyEnabled = try c.decode(Bool.self, forKey: .historyEnabled)
        bindings = try c.decode([HotkeyBinding].self, forKey: .bindings)
        // Pre-existing installs (key absent) keep Ollama and never see the wizard.
        cleanupEngine = try c.decodeIfPresent(CleanupEngine.self, forKey: .cleanupEngine) ?? .ollama
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? true
        summaryEngine = try c.decodeIfPresent(SummaryEngine.self, forKey: .summaryEngine) ?? .ollama
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? "claude-opus-4-8"
        downloadsWatcherEnabled = try c.decodeIfPresent(Bool.self, forKey: .downloadsWatcherEnabled) ?? false
    }
}

// MARK: - Personalization (spec §7)

public struct DictionaryEntry: Codable, Sendable, Equatable {
    public var term: String
    public init(term: String) { self.term = term }
}

public struct Snippet: Codable, Sendable, Equatable {
    public var triggerPhrase: String
    public var body: String

    /// Trigger phrases are capped at 60 characters (spec §7.2).
    public init?(triggerPhrase: String, body: String) {
        let trimmed = triggerPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        self.triggerPhrase = trimmed
        self.body = body
    }
}

public struct Style: Codable, Sendable, Equatable {
    public var appCategory: AppCategory
    public var tone: String
    /// Optional example of the user's own writing in this context; injected
    /// into the cleanup prompt as a few-shot style exemplar.
    public var sample: String

    public init(appCategory: AppCategory, tone: String, sample: String = "") {
        self.appCategory = appCategory
        self.tone = tone
        self.sample = sample
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appCategory = try container.decode(AppCategory.self, forKey: .appCategory)
        tone = try container.decode(String.self, forKey: .tone)
        sample = try container.decodeIfPresent(String.self, forKey: .sample) ?? ""
    }

    public static let defaults: [Style] = [
        Style(appCategory: .email, tone: "warm and professional"),
        Style(appCategory: .chat, tone: "casual and brief"),
        Style(appCategory: .docs, tone: "clear and formal"),
        Style(appCategory: .notes, tone: "neutral, quick-capture"),
        Style(appCategory: .code, tone: "terse and technical"),
        Style(appCategory: .browser, tone: "neutral"),
        Style(appCategory: .terminal, tone: "terse and technical"),
        Style(appCategory: .other, tone: "neutral"),
    ]
}

// MARK: - Context payload (spec §6, §16)

public struct ContextPayload: Sendable, Equatable {
    public var appBundleId: String?
    public var appName: String?
    public var appCategory: AppCategory
    public var nearbyText: String?
    public var properNouns: [String]
    public var recentChatMessages: [String]
    public var isSecureField: Bool

    public init(
        appBundleId: String? = nil,
        appName: String? = nil,
        appCategory: AppCategory = .other,
        nearbyText: String? = nil,
        properNouns: [String] = [],
        recentChatMessages: [String] = [],
        isSecureField: Bool = false
    ) {
        self.appBundleId = appBundleId
        self.appName = appName
        self.appCategory = appCategory
        self.nearbyText = nearbyText
        self.properNouns = properNouns
        self.recentChatMessages = recentChatMessages
        self.isSecureField = isSecureField
    }

    public static let empty = ContextPayload()
}

// MARK: - Scratchpad notes (spec §12)

public struct Note: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

// MARK: - History (spec §12, §16)

public struct TranscriptRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var appBundleId: String?
    public var appCategory: AppCategory
    public var rawText: String
    public var finalText: String
    public var language: String
    public var createdAt: Date
    /// "dictate" or "command"
    public var mode: String

    public init(
        id: UUID = UUID(),
        appBundleId: String?,
        appCategory: AppCategory,
        rawText: String,
        finalText: String,
        language: String,
        createdAt: Date = Date(),
        mode: String
    ) {
        self.id = id
        self.appBundleId = appBundleId
        self.appCategory = appCategory
        self.rawText = rawText
        self.finalText = finalText
        self.language = language
        self.createdAt = createdAt
        self.mode = mode
    }
}
