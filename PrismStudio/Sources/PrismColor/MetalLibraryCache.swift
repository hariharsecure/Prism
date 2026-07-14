import Metal
import os

/// Process-wide, thread-safe cache of runtime-compiled `MTLLibrary`s, keyed by
/// (device, MSL source). [OPT#10 — the safe caching half]
///
/// `MetalColorEngine` is built once per colour-graded/keyed source, and each build
/// recompiled the identical `ColorShaders.source`. This cache compiles that source
/// **once per device** and returns a shared immutable library thereafter.
///
/// **Why sharing is safe.** A compiled `MTLLibrary` is immutable and stateless
/// (Metal documents it thread-safe; `makeFunction(name:)` is thread-safe). The
/// mutable, per-instance objects (command queue, texture caches, pixel pool, and the
/// derived compute PSOs) stay per-instance — the cache never touches them. Keying
/// assumes default `MTLCompileOptions` (the only options this module compiles with).
///
/// (Mirrors PrismCompositor's cache; PrismColor depends only on PrismCore, so the
/// two modules keep independent — but identically-safe — caches.)
enum MetalLibraryCache {
    private struct Key: Hashable {
        let device: ObjectIdentifier
        let source: String
    }

    private static let entries = OSAllocatedUnfairLock(initialState: [Key: MTLLibrary]())

    #if DEBUG
    /// Compile-count seam (DEBUG only): +1 per ACTUAL compile (cache miss).
    static let compileCount = OSAllocatedUnfairLock(initialState: 0)
    static func compilesSoFar() -> Int { compileCount.withLock { $0 } }
    #endif

    /// The shared library for (device, source), compiling once on the first miss.
    static func library(device: MTLDevice, source: String) throws -> MTLLibrary {
        let key = Key(device: ObjectIdentifier(device), source: source)
        if let hit = entries.withLock({ $0[key] }) { return hit }
        let lib = try device.makeLibrary(source: source, options: MTLCompileOptions())
        #if DEBUG
        compileCount.withLock { $0 += 1 }
        #endif
        return entries.withLock {
            if let winner = $0[key] { return winner }
            $0[key] = lib
            return lib
        }
    }
}
