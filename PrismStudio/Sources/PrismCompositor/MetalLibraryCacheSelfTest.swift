import Foundation
import Metal

/// OPT#10 verify harness for `MetalLibraryCache`: proves identical MSL compiles
/// ONCE per device (shared immutable library), that two `SourceEffectGPU` instances
/// share one library object, and that an SDR→HDR compositor toggle drives ZERO
/// extra shader compiles. The compile-count assertions run only in DEBUG (the seam
/// is DEBUG-only); the shared-object assertions run in any config.
public enum MetalLibraryCacheSelfTest {
    public enum Err: Error, CustomStringConvertible {
        case noDevice
        case fail(String)
        public var description: String {
            switch self {
            case .noDevice: return "OPT#10: no Metal device (skip on headless GPU-less host)"
            case .fail(let s): return "OPT#10 MetalLibraryCache: \(s)"
            }
        }
    }

    public static func run() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Err.noDevice }

        // 1. Pure seam: a UNIQUE source (guaranteed miss) compiles exactly once; the
        //    repeat call is a hit returning the SAME immutable object.
        let tag = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
        let uniqueSource = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void opt10_probe_\(tag)(device float* p [[buffer(0)]]) { p[0] = 1.0; }
        """
        #if DEBUG
        let c0 = MetalLibraryCache.compilesSoFar()
        #endif
        let libA = try MetalLibraryCache.library(device: device, source: uniqueSource)
        let libB = try MetalLibraryCache.library(device: device, source: uniqueSource)
        guard libA === libB else { throw Err.fail("identical source returned two different library objects") }
        #if DEBUG
        let c1 = MetalLibraryCache.compilesSoFar()
        guard c1 - c0 == 1 else { throw Err.fail("unique source compiled \(c1 - c0)×, expected exactly 1") }
        #endif

        // 2. Two SourceEffectGPU instances SHARE one library; the 2nd adds no compile.
        #if DEBUG
        let d0 = MetalLibraryCache.compilesSoFar()
        #endif
        let fx1 = try SourceEffectGPU(device: device, width: 64, height: 64)
        #if DEBUG
        let d1 = MetalLibraryCache.compilesSoFar()
        #endif
        let fx2 = try SourceEffectGPU(device: device, width: 64, height: 64)
        #if DEBUG
        let d2 = MetalLibraryCache.compilesSoFar()
        guard d1 - d0 <= 1 else { throw Err.fail("first SourceEffectGPU compiled \(d1 - d0)× (>1)") }
        guard d2 - d1 == 0 else { throw Err.fail("second SourceEffectGPU recompiled identical source (\(d2 - d1) extra)") }
        guard fx1._test_library === fx2._test_library else {
            throw Err.fail("two SourceEffectGPU instances hold DIFFERENT library objects")
        }
        #endif

        // 3. HDR toggle: build an SDR then an HDR compositor. Both compile the SAME
        //    CompositorShaders source (colorMode only selects functions/PSOs), so the
        //    toggle rebuild recompiles NOTHING.
        #if DEBUG
        let e0 = MetalLibraryCache.compilesSoFar()
        #endif
        _ = try MetalCompositor(device: device, width: 64, height: 64, colorMode: .sdr)
        #if DEBUG
        let e1 = MetalLibraryCache.compilesSoFar()
        #endif
        _ = try MetalCompositor(device: device, width: 64, height: 64, colorMode: .hdr)
        #if DEBUG
        let e2 = MetalLibraryCache.compilesSoFar()
        // SourceEffectGPU (step 2) already warmed CompositorShaders → both compositor
        // builds are cache hits.
        guard e1 - e0 == 0 else { throw Err.fail("SDR compositor recompiled a warmed library (\(e1 - e0) extra)") }
        guard e2 - e1 == 0 else { throw Err.fail("SDR→HDR toggle recompiled shaders (\(e2 - e1) extra)") }
        #endif

        // 4. The compositor + SourceEffectGPU converge on ONE shared object.
        let shared = try MetalLibraryCache.library(device: device, source: CompositorShaders.source)
        #if DEBUG
        guard shared === fx1._test_library else {
            throw Err.fail("compositor library and SourceEffectGPU library diverge")
        }
        #endif
        _ = shared

        print("  ✓ OPT#10 MetalLibraryCache: identical MSL compiles once/device — unique source 1 compile, 2×SourceEffectGPU share one library (+0 recompile), SDR→HDR toggle +0 recompile")
    }
}
