import Foundation

/// Prompts for long-form transcript summarization. Same ethos as the
/// dictation cleanup contract: faithful to what was said, never generative.
public enum SummaryPrompt {

    public static func build(template: SummaryTemplate, transcript: String) -> PromptBuilder.Prompt {
        let base = """
        You summarize transcripts of recorded audio. The transcript below has \
        no speaker labels and imperfect punctuation — that is expected.

        Rules:
        - Report only what was said. Never invent facts, names, numbers, or commitments.
        - Omit any section that would be empty rather than padding it.
        - Write in clear, complete sentences. Output Markdown with `##` section headings.
        - Do not include preamble or commentary — output only the summary document.
        """

        let shape: String = switch template {
        case .auto: """
            Sections:
            ## Overview — 2–3 sentences on what this recording is about.
            ## Key points — the substantive points, as bullets.
            ## Decisions — decisions that were made, if any.
            ## Action items — tasks someone committed to, with the owner when stated.
            """
        case .meeting: """
            Sections:
            ## Overview — what meeting this was and what it covered, 2–3 sentences.
            ## Attendees — names mentioned as present, if identifiable.
            ## Discussion — the main threads, as bullets.
            ## Decisions — decisions that were made.
            ## Action items — tasks with owners and deadlines when stated.
            ## Next steps — agreed follow-ups or the next meeting, if mentioned.
            """
        case .lecture: """
            Sections:
            ## Topic — what this talk or lecture is about, 1–2 sentences.
            ## Main points — the argument or material, as structured bullets.
            ## Key takeaways — the 3–5 things worth remembering (one takeaway per bullet).
            """
        case .memo: """
            This is a personal voice memo. Produce:
            ## Note — the memo's content as a cleaned-up narrative, keeping the speaker's intent and voice.
            ## To-dos — anything phrased as a task or reminder, as a to-do checklist.
            """
        case .interview: """
            Sections:
            ## Context — who appears to be talking and about what, 1–2 sentences.
            ## Questions & answers — each substantive question with a distilled answer.
            ## Highlights — the most notable statements or admissions.
            """
        }

        return PromptBuilder.Prompt(
            system: base + "\n\n" + shape,
            user: "Transcript:\n\n" + transcript)
    }
}
