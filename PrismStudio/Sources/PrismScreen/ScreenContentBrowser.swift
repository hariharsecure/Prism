import CoreGraphics
import Foundation
import PrismCore
import ScreenCaptureKit

/// Async enumeration of shareable screen content (displays, windows, running
/// applications) as `SourceDescriptor`s for the "add source" UI.
///
/// ID scheme (stable, parseable by `ScreenSource`):
///  - display:      `display:<CGDirectDisplayID>`
///  - window:       `window:<CGWindowID>`
///  - application:  `app:<bundle identifier>`
///
/// Note: calling any of these at runtime requires Screen Recording permission
/// (TCC). Enumeration itself is what triggers the system prompt on first use.
public enum ScreenContentBrowser {

    /// Everything shareable: displays, then applications, then windows.
    public static func descriptors(onScreenWindowsOnly: Bool = true) async throws -> [SourceDescriptor] {
        let content = try await shareableContent(onScreenWindowsOnly: onScreenWindowsOnly)
        return displayDescriptors(content)
            + applicationDescriptors(content)
            + windowDescriptors(content)
    }

    /// Displays only (kind `.display`).
    public static func displays() async throws -> [SourceDescriptor] {
        displayDescriptors(try await shareableContent(onScreenWindowsOnly: true))
    }

    /// Windows only (kind `.window`). Untitled/ornament windows are skipped —
    /// they are overlay chrome (menu bar items, tooltips) users never mean.
    public static func windows(onScreenWindowsOnly: Bool = true) async throws -> [SourceDescriptor] {
        windowDescriptors(try await shareableContent(onScreenWindowsOnly: onScreenWindowsOnly))
    }

    /// Running applications only (kind `.application`).
    public static func applications() async throws -> [SourceDescriptor] {
        applicationDescriptors(try await shareableContent(onScreenWindowsOnly: true))
    }

    // MARK: - Internals

    private static func shareableContent(onScreenWindowsOnly: Bool) async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: onScreenWindowsOnly)
    }

    private static func displayDescriptors(_ content: SCShareableContent) -> [SourceDescriptor] {
        content.displays
            .sorted { $0.displayID < $1.displayID }
            .enumerated()
            .map { index, display in
                let isMain = CGDisplayIsMain(display.displayID) != 0
                let name = isMain ? "Display \(index + 1) (Main)" : "Display \(index + 1)"
                var detail = "\(display.width)×\(display.height) pt"
                if let mode = CGDisplayCopyDisplayMode(display.displayID) {
                    detail += " · \(mode.pixelWidth)×\(mode.pixelHeight) px"
                }
                return SourceDescriptor(
                    kind: .display,
                    id: "display:\(display.displayID)",
                    name: name,
                    detail: detail
                )
            }
    }

    private static func windowDescriptors(_ content: SCShareableContent) -> [SourceDescriptor] {
        content.windows
            .compactMap { window -> SourceDescriptor? in
                guard let title = window.title, !title.isEmpty else { return nil }
                let appName = window.owningApplication?.applicationName ?? "Unknown App"
                return SourceDescriptor(
                    kind: .window,
                    id: "window:\(window.windowID)",
                    name: "\(title) — \(appName)",
                    detail: window.owningApplication?.bundleIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func applicationDescriptors(_ content: SCShareableContent) -> [SourceDescriptor] {
        content.applications
            .compactMap { app -> SourceDescriptor? in
                guard !app.bundleIdentifier.isEmpty else { return nil }
                let name = app.applicationName.isEmpty ? app.bundleIdentifier : app.applicationName
                return SourceDescriptor(
                    kind: .application,
                    id: "app:\(app.bundleIdentifier)",
                    name: name,
                    detail: "\(app.bundleIdentifier) · pid \(app.processID)"
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
