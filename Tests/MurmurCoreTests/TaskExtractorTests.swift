import Testing
@testable import MurmurCore

@Test func extractsFromActionItemsSection() {
    let body = """
    ## Overview
    We shipped it.
    ## Action items
    - Prepare the deck (@Priya)
    - Send the contract
    - Book the room (@Sam)
    ## Decisions
    Launch Friday.
    """
    let tasks = TaskExtractor.parse(body)
    #expect(tasks.count == 3)
    #expect(tasks[0] == ExtractedTask(title: "Prepare the deck", assignee: "Priya"))
    #expect(tasks[1] == ExtractedTask(title: "Send the contract", assignee: "Unassigned"))
    #expect(tasks[2] == ExtractedTask(title: "Book the room", assignee: "Sam"))
}

@Test func extractsFromToDosHeading() {
    let body = "## Note\nstuff\n## To-dos\n- Buy milk\n- Call mum (@me)"
    let tasks = TaskExtractor.parse(body)
    #expect(tasks == [
        ExtractedTask(title: "Buy milk", assignee: "Unassigned"),
        ExtractedTask(title: "Call mum", assignee: "me"),
    ])
}

@Test func extractsNothingWithoutActionSection() {
    #expect(TaskExtractor.parse("## Overview\nno tasks here\n## Decisions\nnone").isEmpty)
}

@Test func stopsAtNextHeadingAndSkipsBlanks() {
    let body = "## Action items\n- Real task (@Sue)\n\n## Next steps\n- Not a task"
    #expect(TaskExtractor.parse(body) == [ExtractedTask(title: "Real task", assignee: "Sue")])
}

@Test func toleratesPipeAndDashAssigneeForms() {
    let body = """
    ## Action items
    - Send the deck | Priya
    - Book the room — Sam
    - Ship it | Unassigned
    - Review a long clause that is not an owner
    """
    #expect(TaskExtractor.parse(body) == [
        ExtractedTask(title: "Send the deck", assignee: "Priya"),
        ExtractedTask(title: "Book the room", assignee: "Sam"),
        ExtractedTask(title: "Ship it", assignee: "Unassigned"),
        ExtractedTask(title: "Review a long clause that is not an owner", assignee: "Unassigned"),
    ])
}
