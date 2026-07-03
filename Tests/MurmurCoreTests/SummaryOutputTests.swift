import Testing
@testable import MurmurCore

@Test func parseSplitsTitleKeepsBody() {
    let raw = """
    TITLE: Q3 Launch Sync
    ## Overview
    We shipped it.
    ## Action items
    - Prepare the deck (@Priya)
    """
    let out = SummaryOutput.parse(raw)
    #expect(out.title == "Q3 Launch Sync")
    #expect(out.body.contains("## Overview"))
    #expect(!out.body.contains("TITLE:"))
    #expect(out.body.contains("Prepare the deck"))   // tasks stay visible in the body
}

@Test func parseToleratesMissingTitle() {
    let out = SummaryOutput.parse("## Overview\nJust a summary.")
    #expect(out.title == nil)
    #expect(out.body == "## Overview\nJust a summary.")
}

@Test func promptRequestsTitleAndOwnerMarker() {
    let system = SummaryPrompt.build(template: .auto, transcript: "t").system
    #expect(system.contains("TITLE:"))
    #expect(system.contains("(@Name)"))
}
