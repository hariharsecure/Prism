import CoreVideo
import XCTest
@testable import PrismCore

/// G2 hardening (reproduce-first + negative control): `PixelBufferPool` was
/// created with only `kCVPixelBufferPoolMinimumBufferCountKey` and never flushed,
/// so after a transient spike pushed the outstanding count to K it retained K
/// IOSurfaces for process lifetime. `flushExcess()` (CVPixelBufferPoolFlush with
/// `.excessBuffers`) sheds the unused ones at idle seams without disturbing
/// steady-state recycling.
///
/// Observable: a **sentinel byte** written into each buffer. A pool *recycle*
/// hands back the same IOSurface with its bytes intact (sentinel survives); a
/// *fresh* allocation returns a kernel-zeroed IOSurface (sentinel gone). This is
/// robust where IOSurface *IDs* are not — the kernel promptly reuses freed
/// surface IDs, so ID identity cannot tell "recycled" from "freed + reallocated".
final class PixelBufferPoolFlushExcessTests: XCTestCase {

    private let minimum = 2
    private let spikeK = 32
    private let W = 64
    private let H = 64
    private let sentinel: UInt8 = 0xAB

    private func firstByte(_ b: CVPixelBuffer) -> UInt8 {
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        return CVPixelBufferGetBaseAddress(b)!.load(as: UInt8.self)
    }

    private func paint(_ b: CVPixelBuffer, _ v: UInt8) {
        CVPixelBufferLockBaseAddress(b, [])
        defer { CVPixelBufferUnlockBaseAddress(b, []) }
        CVPixelBufferGetBaseAddress(b)!.storeBytes(of: v, as: UInt8.self)
    }

    /// Simulate a transient spike: mint `count` buffers simultaneously (holding
    /// refs forces the pool to allocate distinct IOSurfaces), stamp each with the
    /// sentinel, then release — leaving `count` painted buffers on the pool's free
    /// list.
    private func paintSpike(_ pool: PixelBufferPool, count: Int) throws {
        try autoreleasepool {
            var held: [CVPixelBuffer] = []
            held.reserveCapacity(count)
            for _ in 0..<count {
                let buf = try pool.makeBuffer()
                paint(buf, sentinel)
                held.append(buf)
            }
            held.removeAll() // release → painted surfaces return to the free list
        }
    }

    /// Mint `count` buffers simultaneously and report how many still carry the
    /// sentinel (i.e. were recycled from the resident free list rather than freshly
    /// allocated).
    private func probeRecycledCount(_ pool: PixelBufferPool, count: Int) throws -> Int {
        var recycled = 0
        try autoreleasepool {
            var held: [CVPixelBuffer] = []
            held.reserveCapacity(count)
            for _ in 0..<count {
                let buf = try pool.makeBuffer()
                if firstByte(buf) == sentinel { recycled += 1 }
                held.append(buf)
            }
            held.removeAll()
        }
        return recycled
    }

    // MARK: - Reproduce + negative control

    /// NEGATIVE CONTROL: without `flushExcess`, once the pool has grown to K it
    /// permanently retains those K IOSurfaces — a repeat spike after releasing all
    /// refs is served almost entirely from the resident (painted) free list.
    func testRetentionReproduces_withoutFlush_poolNeverShrinks() throws {
        let pool = try PixelBufferPool(width: W, height: H, minimumBufferCount: minimum)

        try paintSpike(pool, count: spikeK)
        // No flush. The pool still holds ~K painted free buffers.
        let recycled = try probeRecycledCount(pool, count: spikeK)
        XCTAssertGreaterThanOrEqual(recycled, spikeK - minimum,
            "NEGATIVE CONTROL: pool retained the high-watermark — a repeat spike recycles the resident painted IOSurfaces (≥ K − minimum); it never shed them")
    }

    // MARK: - flushExcess sheds the excess

    /// After a spike + release, `flushExcess()` frees the resident (unused) buffers,
    /// so re-minting K draws mostly FRESH (kernel-zeroed) IOSurfaces — the direct
    /// contrast with the negative control above.
    func testFlushExcess_shedsPostSpikeExcess() throws {
        let pool = try PixelBufferPool(width: W, height: H, minimumBufferCount: minimum)

        try paintSpike(pool, count: spikeK)
        pool.flushExcess()

        let recycled = try probeRecycledCount(pool, count: spikeK)
        XCTAssertLessThanOrEqual(recycled, minimum,
            "flushExcess should shed the resident excess, so the next spike allocates a fresh (zeroed) batch — at most ~minimum painted survivors")
    }

    // MARK: - Hot path unaffected

    /// Steady state (mint == release each iteration) must keep recycling the same
    /// warm buffer with ZERO growth, whether or not flush is used — proving the
    /// flush touches only the free list and the per-frame allocation path is
    /// unchanged.
    func testSteadyStateRecycling_isAllocationFree() throws {
        let pool = try PixelBufferPool(width: W, height: H, minimumBufferCount: minimum)

        // Prime one buffer with the sentinel so we can watch it recycle.
        try autoreleasepool {
            let b = try pool.makeBuffer()
            paint(b, sentinel)
        }

        var recycledHits = 0
        for _ in 0..<200 {
            try autoreleasepool {
                let b = try pool.makeBuffer()
                if firstByte(b) == sentinel { recycledHits += 1 }
                // released at scope exit → returned to the free list for reuse
            }
        }
        XCTAssertGreaterThanOrEqual(recycledHits, 190,
            "steady-state 1-in/1-out must recycle the warm buffer (no fresh allocation per frame)")

        // Recycling still works after a flush (flush must not break the hot path).
        try autoreleasepool {
            let b = try pool.makeBuffer()
            XCTAssertNoThrow(paint(b, sentinel))
        }
        pool.flushExcess()
        for _ in 0..<50 {
            try autoreleasepool {
                let b = try pool.makeBuffer()          // must still vend buffers
                XCTAssertEqual(CVPixelBufferGetWidth(b), W)
            }
        }
    }
}
