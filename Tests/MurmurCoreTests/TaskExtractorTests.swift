import Testing
@testable import MurmurCore

@Test func extractsTasksWithAndWithoutAssignee() {
    let raw = """
    TITLE: x
    ## Overview
    body
    <!--TASKS
    - Prepare the deck | Priya
    - Send the contract | Unassigned
    - Book the room
    -->
    """
    let tasks = TaskExtractor.parse(raw)
    #expect(tasks.count == 3)
    #expect(tasks[0] == ExtractedTask(title: "Prepare the deck", assignee: "Priya"))
    #expect(tasks[1].assignee == "Unassigned")
    #expect(tasks[2] == ExtractedTask(title: "Book the room", assignee: "Unassigned"))
}

@Test func extractsNothingWhenNoBlock() {
    #expect(TaskExtractor.parse("## Overview\nno tasks here").isEmpty)
}

@Test func skipsBlankAndMalformedLines() {
    let raw = "<!--TASKS\n- \n-  | Bob\nReal task | Sue\n-->"
    let tasks = TaskExtractor.parse(raw)
    #expect(tasks == [ExtractedTask(title: "Real task", assignee: "Sue")])
}
