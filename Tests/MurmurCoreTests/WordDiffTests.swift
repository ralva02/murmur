import Testing
@testable import MurmurCore

@Test func wordDiffMarksChanges() {
    let d = WordDiff.diff(old: "um lets meet tuesday", new: "Let's meet Friday.")
    #expect(d.contains(where: { if case .removed(let w) = $0 { return w == "um" }; return false }))
    #expect(d.contains(where: { if case .added(let w) = $0 { return w == "Friday." }; return false }))
    #expect(d.contains(where: { if case .same(let w) = $0 { return w == "meet" }; return false }))
}

@Test func identicalTextsDiffToAllSame() {
    let d = WordDiff.diff(old: "same words here", new: "same words here")
    #expect(d.allSatisfy { if case .same = $0 { return true }; return false })
    #expect(d.count == 3)
}

@Test func emptyOldIsAllAdded() {
    let d = WordDiff.diff(old: "", new: "brand new")
    #expect(d.count == 2)
    #expect(d.allSatisfy { if case .added = $0 { return true }; return false })
}
