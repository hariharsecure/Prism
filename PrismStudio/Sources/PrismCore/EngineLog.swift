import Foundation
import os

/// One logger + signposter per subsystem, so Instruments traces line up
/// across modules (DESIGN.md §3.5 — measurement is a feature).
public enum EngineLog {
    public static let subsystem = "studio.prism"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    public static func signposter(_ category: String) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category)
    }
}
