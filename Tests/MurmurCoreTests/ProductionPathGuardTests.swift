import Foundation
import Testing
@testable import MurmurCore

// Regression guard for the 2026-07-03 data-loss incident: constructing a
// production-path store from a test process must trap, not proceed.
@Test func productionPathStoreTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        _ = AppStore()
    }
}

@Test func migrationWithDefaultPathsTrapsUnderTests() async {
    await #expect(processExitsWith: .failure) {
        AppStore.migrateLegacyDataIfNeeded()
    }
}
