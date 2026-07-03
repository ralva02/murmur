import Foundation
import os

/// Unified logging for the dictation chain. Read with:
///   log show --last 10m --predicate 'subsystem == "com.raul.wisprrr"'
enum Diag {
    static let app = Logger(subsystem: "com.raul.wisprrr", category: "app")
    static let hotkeys = Logger(subsystem: "com.raul.wisprrr", category: "hotkeys")
    static let dictation = Logger(subsystem: "com.raul.wisprrr", category: "dictation")
    static let injection = Logger(subsystem: "com.raul.wisprrr", category: "injection")
}
