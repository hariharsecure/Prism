import Metal
import os

/// Process-wide, thread-safe cache of runtime-compiled `MTLLibrary`s, keyed by
/// (device, MSL source). [OPT#10 — the safe caching half]
///
/// SPM can't build `.metal` files into a library target, so every compositor /
/// `SourceEffectGPU` compiled its embedded MSL from source at init via
/// `device.makeLibrary(source:)`. Identical source therefore recompiled once per
/// instance — and once per **HDR toggle** (which rebuilds the whole compositor) and
/// once per **per-source FX** creation. This cache makes identical source compile
/// **once per device**, returning a shared library on every subsequent build.
///
/// **Why sharing is safe.** A compiled `MTLLibrary` is immutable and stateless —
/// Metal documents it as thread-safe; `makeFunction(name:)` on it is thread-safe.
/// Sharing one immutable library across instances/threads introduces no race. The
/// MUTABLE, per-instance objects (command queues, `CVMetalTextureCache`s, pixel
/// pools, and the derived `MTLRenderPipelineState`/`MTLComputePipelineState`s) stay
/// per-instance — this is the isolation the audit says to preserve; the cache does
/// not touch them.
///
/// Keying assumes **default `MTLCompileOptions`** (every current caller passes
/// `MTLCompileOptions()`); options are not part of the key, so a caller that ever
/// needs non-default options must not use this cache.
enum MetalLibraryCache {
    private struct Key: Hashable {
        let device: ObjectIdentifier
        let source: String
    }

    private static let entries = OSAllocatedUnfairLock(initialState: [Key: MTLLibrary]())

    #if DEBUG
    /// Compile-count seam (DEBUG only): increments once per ACTUAL `makeLibrary`
    /// compile (a cache miss). A test asserts two instances on one device drive
    /// exactly ONE compile, and that an SDR→HDR compositor toggle drives zero extra.
    static let compileCount = OSAllocatedUnfairLock(initialState: 0)
    static func compilesSoFar() -> Int { compileCount.withLock { $0 } }
    #endif

    /// The shared library for (device, source), compiling once on the first miss.
    /// Subsequent calls with equal source on the same device return the SAME object.
    static func library(device: MTLDevice, source: String) throws -> MTLLibrary {
        let key = Key(device: ObjectIdentifier(device), source: source)
        if let hit = entries.withLock({ $0[key] }) { return hit }

        // Compile OUTSIDE the lock — compilation is milliseconds; don't serialize
        // every device/source behind one lock. A rare race can compile twice; the
        // first stored library wins and both callers receive an equivalent immutable
        // library (correctness is unaffected — only a one-off redundant compile).
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
