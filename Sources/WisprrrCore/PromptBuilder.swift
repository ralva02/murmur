import Foundation

/// Builds the prompts sent to the cleanup LLM. The cleanup prompt encodes the
/// spec §3.2 contract: minimal-edit smoothing, never free generation.
public enum PromptBuilder {

    public struct Prompt: Sendable, Equatable {
        public let system: String
        public let user: String
    }

    public static func cleanupPrompt(
        rawTranscript: String,
        context: ContextPayload,
        dictionary: [DictionaryEntry],
        style: Style?
    ) -> Prompt {
        var lines: [String] = []
        lines.append("""
        You clean up raw speech-to-text transcripts. The user spoke the text; \
        your job is to output exactly what they would have typed, nothing more.

        Rules:
        - Make the smallest edits possible. Keep the user's wording and voice.
        - Never add facts, content, greetings, or sign-offs that were not spoken.
        - Remove filler words (um, uh, like, you know) and false starts.
        - Resolve self-corrections to the final intent: "let's meet Tuesday, wait no, Friday" becomes "Let's meet Friday".
        - Add punctuation and capitalization.
        - Format as a numbered or bulleted list only when the speech clearly implies one.
        - Output only the cleaned text. No commentary, no quotes, no markdown fences.
        """)

        if !dictionary.isEmpty {
            let terms = dictionary.map(\.term).joined(separator: ", ")
            lines.append("Dictionary — spell these terms exactly as written when spoken: \(terms).")
        }
        if let style {
            lines.append("Tone: \(style.tone). Match it without changing the message.")
        }
        if context.appCategory == .code || context.appCategory == .terminal {
            lines.append("This is a coding context: preserve identifier casing such as camelCase and snake_case, file names, and technical terms verbatim.")
        }
        if let app = context.appName ?? context.appBundleId {
            lines.append("The text will be inserted into \(app) (\(context.appCategory.rawValue)).")
        }
        if !context.properNouns.isEmpty {
            lines.append("Names visible on screen — use these spellings if spoken: \(context.properNouns.joined(separator: ", ")).")
        }
        if let nearby = context.nearbyText, !nearby.isEmpty {
            lines.append("Text near the cursor, for spelling and context only (do not repeat it):\n\(nearby)")
        }
        if !context.recentChatMessages.isEmpty {
            lines.append("Recent messages in this conversation, for context only:\n\(context.recentChatMessages.joined(separator: "\n"))")
        }

        return Prompt(system: lines.joined(separator: "\n\n"), user: rawTranscript)
    }

    public static func commandPrompt(instruction: String, selection: String) -> Prompt {
        let system = """
        You edit text according to an instruction. Return only the rewritten text — \
        no commentary, no quotes, no markdown fences. Preserve the meaning unless \
        the instruction says otherwise.
        """
        let user = """
        Instruction: \(instruction)

        Text:
        \(selection)
        """
        return Prompt(system: system, user: user)
    }
}
