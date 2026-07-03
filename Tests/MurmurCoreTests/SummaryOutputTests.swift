import Testing
@testable import MurmurCore

@Test func parseSplitsTitleAndStripsTaskBlock() {
    let raw = """
    TITLE: Q3 Launch Sync
    ## Overview
    We shipped it.
    <!--TASKS
    - Prepare the deck | Priya
    - Send the contract | Unassigned
    -->
    """
    let out = SummaryOutput.parse(raw)
    #expect(out.title == "Q3 Launch Sync")
    #expect(out.body.contains("## Overview"))
    #expect(!out.body.contains("TITLE:"))
    #expect(!out.body.contains("TASKS"))
    #expect(!out.body.contains("Prepare the deck"))
}

@Test func parseToleratesMissingTitleAndTasks() {
    let out = SummaryOutput.parse("## Overview\nJust a summary.")
    #expect(out.title == nil)
    #expect(out.body == "## Overview\nJust a summary.")
}

@Test func promptRequestsTitleAndTasks() {
    let system = SummaryPrompt.build(template: .auto, transcript: "t").system
    #expect(system.contains("TITLE:"))
    #expect(system.contains("<!--TASKS"))
}
