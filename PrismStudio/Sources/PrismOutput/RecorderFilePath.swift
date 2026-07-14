import Foundation

/// Path math shared by every recorder so a new take can NEVER destructively
/// overwrite a prior take's file (sol HIGH #1 — data loss).
///
/// Before, `MovieRecorder`/`AudioTrackRecorder` unconditionally `removeItem`'d any
/// file already at the destination path. Combined with fixed per-source ISO/
/// multitrack names (`iso-<source>.mov`, `audio-<source>.mov`) and a
/// second-resolution program name, a second take reusing the same path silently
/// deleted the first take's recording. The session layer now assigns unique
/// per-take names, and this helper is the last-line guard: if the requested path
/// is already occupied, record to a uniquified sibling instead of clobbering it.
public enum RecorderFilePath {
    /// Returns `requested` when nothing exists there, otherwise the first free
    /// `name-2.ext`, `name-3.ext`, … sibling in the same directory. Pure path math
    /// (creates no files); the caller opens the returned URL. Never deletes.
    ///
    /// Public so every user-facing save/export path — recorders (program/ISO/
    /// multitrack/vertical), the replay/highlight/clip muxer, and the FCPXML
    /// exporter — resolves a free sibling instead of destroying a prior file
    /// (sol #17: replay/clip second-resolution names clobbered earlier clips).
    public static func nonClobbering(_ requested: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: requested.path) else { return requested }
        let dir = requested.deletingLastPathComponent()
        let ext = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
