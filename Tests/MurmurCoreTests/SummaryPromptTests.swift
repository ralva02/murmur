import Testing
@testable import MurmurCore

@Test func autoTemplateHasCoreSections() {
    let p = SummaryPrompt.build(template: .auto, transcript: "we decided to ship friday")
    #expect(p.system.contains("Overview"))
    #expect(p.system.contains("Action items"))
    #expect(p.system.contains("Never invent"))
    #expect(p.user.contains("we decided to ship friday"))
}

@Test func templatesSpecialize() {
    #expect(SummaryPrompt.build(template: .meeting, transcript: "t").system.contains("Decisions"))
    #expect(SummaryPrompt.build(template: .lecture, transcript: "t").system.contains("takeaway"))
    #expect(SummaryPrompt.build(template: .memo, transcript: "t").system.contains("to-do"))
    #expect(SummaryPrompt.build(template: .interview, transcript: "t").system.contains("question"))
}

@Test func allTemplatesDemandMarkdownAndFidelity() {
    for template in SummaryTemplate.allCases {
        let system = SummaryPrompt.build(template: template, transcript: "t").system
        #expect(system.contains("Markdown") || system.contains("markdown"))
        #expect(system.contains("Never invent"))
    }
}
