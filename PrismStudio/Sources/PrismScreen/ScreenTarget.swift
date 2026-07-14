import CoreGraphics
import Foundation
import PrismCore

/// Typed errors for the PrismScreen module.
public enum ScreenSourceError: Error, CustomStringConvertible {
    /// The descriptor is not a screen kind, or its id doesn't parse.
    case invalidDescriptor(SourceDescriptor)
    /// The display/window/app the descriptor points at no longer exists.
    case contentNotFound(String)
    /// `start()` called while the source isn't idle/failed.
    case notIdle(SourceState)
    /// No display available to anchor an application filter on.
    case noDisplayAvailable

    public var description: String {
        switch self {
        case .invalidDescriptor(let d): return "invalid screen descriptor \(d.kind.rawValue):\(d.id)"
        case .contentNotFound(let id): return "shareable content not found for \(id)"
        case .notIdle(let s): return "start() while state == \(s.rawValue)"
        case .noDisplayAvailable: return "no display available for application capture"
        }
    }
}

/// What a `ScreenSource` captures, parsed from a `SourceDescriptor`
/// (see `ScreenContentBrowser` for the id scheme).
enum ScreenTarget {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case application(bundleID: String)

    init(descriptor: SourceDescriptor) throws {
        func value(after prefix: String) -> String? {
            descriptor.id.hasPrefix(prefix) ? String(descriptor.id.dropFirst(prefix.count)) : nil
        }
        switch descriptor.kind {
        case .display:
            guard let raw = value(after: "display:"), let id = UInt32(raw) else {
                throw ScreenSourceError.invalidDescriptor(descriptor)
            }
            self = .display(CGDirectDisplayID(id))
        case .window:
            guard let raw = value(after: "window:"), let id = UInt32(raw) else {
                throw ScreenSourceError.invalidDescriptor(descriptor)
            }
            self = .window(CGWindowID(id))
        case .application:
            guard let bundleID = value(after: "app:"), !bundleID.isEmpty else {
                throw ScreenSourceError.invalidDescriptor(descriptor)
            }
            self = .application(bundleID: bundleID)
        default:
            throw ScreenSourceError.invalidDescriptor(descriptor)
        }
    }
}
