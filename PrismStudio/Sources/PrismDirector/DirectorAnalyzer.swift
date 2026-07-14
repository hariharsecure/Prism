import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PrismCore
import Vision

/// Errors thrown by the analyzer.
public enum DirectorError: Error, CustomStringConvertible {
    /// The Vision face-rectangles request threw.
    case faceRequestFailed(underlying: Error)
    /// A frame arrived in a pixel format the motion sampler can't read.
    case unsupportedPixelFormat(OSType)
    public var description: String {
        switch self {
        case .faceRequestFailed(let e): return "director face request failed: \(e)"
        case .unsupportedPixelFormat(let f): return "director: unsupported pixel format \(f)"
        }
    }
}

/// Runs lightweight Vision analysis on submitted frames **off the render path**
/// (DESIGN §3.5 — "the render loop never waits on ML"), producing one
/// `SourceSignal` per source. Mirrors `PersonSegmenter`'s discipline: `submit`
/// is non-blocking, work runs on a private serial queue, a rate limiter caps
/// Vision work per source (default ~8 Hz — auto-direction is a slow decision,
/// it doesn't need 60 Hz), and while a request is in flight the newest frame
/// per source replaces any parked one (**latest wins**).
///
/// Analysis is two cheap things:
///  1. `VNDetectFaceRectanglesRequest` — face presence + confidence + bounds.
///     Rectangles (not landmarks/segmentation) is the cheapest face request and
///     TCC-free on static buffers; bounds are converted to top-left-origin.
///  2. Frame-difference **motion energy** — mean absolute luma delta against
///     this source's previous analyzed frame, sampled on a coarse grid.
///
/// Audio level is a stub the app fills into the emitted signal; the analyzer
/// never reads audio.
///
/// Thread-safety: `submit`/`analyzeNow`/`stats` are safe from any thread. Set
/// `onSignal`/`onError` before submitting. Callbacks arrive on the analyzer's
/// serial queue.
public final class DirectorAnalyzer: @unchecked Sendable {
    /// Pipeline counters (all monotonic).
    public struct Stats: Sendable {
        public let submitted: Int
        public let rateLimited: Int
        public let superseded: Int
        public let processed: Int
        public let faces: Int
        public let errors: Int
    }

    /// Emitted for every analyzed frame (whether or not a face was found).
    public var onSignal: ((SourceSignal) -> Void)?
    /// Emitted when a Vision run throws.
    public var onError: ((Error) -> Void)?

    /// Per-source target analysis rate in Hz; faster frames are dropped.
    public let targetRate: Double
    /// Faces below this confidence are treated as "no face".
    public let minFaceConfidence: Float
    /// Grid resolution for motion sampling (gridN × gridN samples).
    private let gridN = 24

    private let queue = DispatchQueue(label: "studio.prism.director.analyzer", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [SourceID: VideoFrame] = [:]
    private var lastAccepted: [SourceID: Double] = [:]
    private var prevGrid: [SourceID: [Float]] = [:]
    private var busy = false
    private var submittedCount = 0
    private var rateLimitedCount = 0
    private var supersededCount = 0
    private var processedCount = 0
    private var faceCount = 0
    private var errorCount = 0
    private let logger = EngineLog.logger("director")

    public init(targetRate: Double = 8, minFaceConfidence: Float = 0.3) {
        self.targetRate = max(targetRate, 0.1)
        self.minFaceConfidence = minFaceConfidence
    }

    /// Non-blocking. Rate-limits per source on house-time PTS; if a request is
    /// in flight the frame parks in that source's single pending slot,
    /// replacing (dropping) any frame already parked there.
    public func submit(_ frame: VideoFrame) {
        let seconds = frame.pts.seconds.isFinite ? frame.pts.seconds : HouseClock.nowSeconds()
        lock.lock()
        submittedCount += 1
        let last = lastAccepted[frame.source] ?? -Double.infinity
        // Rate-limit only when time moved FORWARD by less than the interval. If
        // house time went backward for this source (a reconnect with reset PTS),
        // `seconds - last` would be negative and rate-limit every frame forever
        // → the source goes dark. Treat backward time as a discontinuity: accept
        // the frame and re-baseline `lastAccepted` to the new clock.
        if seconds >= last && seconds - last < 1.0 / targetRate {
            rateLimitedCount += 1
            lock.unlock()
            return
        }
        lastAccepted[frame.source] = seconds
        if pending[frame.source] != nil { supersededCount += 1 }
        pending[frame.source] = frame
        let shouldStart = !busy
        if shouldStart { busy = true }
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    /// True when no request is running and nothing is parked (test/teardown aid).
    public var isIdle: Bool {
        lock.lock(); defer { lock.unlock() }
        return !busy && pending.isEmpty
    }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return Stats(submitted: submittedCount, rateLimited: rateLimitedCount,
                     superseded: supersededCount, processed: processedCount,
                     faces: faceCount, errors: errorCount)
    }

    /// Synchronous one-shot analysis — bypasses the queue and rate limiter.
    /// For tests and offline use, NOT the live path. Updates the per-source
    /// motion history so a following call sees a real frame delta.
    public func analyzeNow(_ frame: VideoFrame) throws -> SourceSignal {
        try performAnalysis(frame)
    }

    // MARK: - Worker

    private func drain() {
        while true {
            lock.lock()
            guard let (source, frame) = pending.first else {
                busy = false
                lock.unlock()
                return
            }
            pending.removeValue(forKey: source)
            lock.unlock()

            do {
                let signal = try performAnalysis(frame)
                lock.lock()
                processedCount += 1
                if signal.facePresent { faceCount += 1 }
                lock.unlock()
                onSignal?(signal)
            } catch {
                lock.lock(); processedCount += 1; errorCount += 1; lock.unlock()
                logger.error("analysis failed for \(frame.source): \(error)")
                onError?(error)
            }
        }
    }

    private func performAnalysis(_ frame: VideoFrame) throws -> SourceSignal {
        // 1. Face presence + bounds.
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw DirectorError.faceRequestFailed(underlying: error)
        }
        var present = false
        var confidence: Float = 0
        var bounds: CGRect? = nil
        let faces = request.results ?? []
        if let best = faces.max(by: { $0.boundingBox.normalizedArea < $1.boundingBox.normalizedArea }),
           best.confidence >= minFaceConfidence {
            present = true
            confidence = best.confidence
            // Vision boundingBox is normalized, bottom-left origin → flip to top-left.
            let bb = best.boundingBox
            bounds = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        }

        // 2. Motion energy vs this source's previous grid (off render path;
        //    the CPU read is allowed here — rate-limited, never the hot path).
        let grid = sampleLumaGrid(frame.pixelBuffer)
        var motion: Float = 0
        lock.lock()
        if let prev = prevGrid[frame.source], prev.count == grid.count, !grid.isEmpty {
            var acc: Float = 0
            for i in 0..<grid.count { acc += abs(grid[i] - prev[i]) }
            motion = min(1, acc / Float(grid.count))
        }
        prevGrid[frame.source] = grid
        lock.unlock()

        return SourceSignal(source: frame.source, pts: frame.pts,
                            facePresent: present, faceConfidence: confidence,
                            faceBounds: bounds, motionEnergy: motion, audioLevel: nil)
    }

    /// Coarse luma grid in 0…1, `gridN`×`gridN` samples. Handles 32BGRA and
    /// bi-planar 420 (full/video range); returns an empty array for anything
    /// else (motion simply reads 0). Locks the base address — permitted here
    /// (off render path, rate-limited).
    private func sampleLumaGrid(_ buffer: CVPixelBuffer) -> [Float] {
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        guard w > 0, h > 0 else { return [] }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var out = [Float](repeating: 0, count: gridN * gridN)

        switch fmt {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self)
            else { return [] }
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            for gy in 0..<gridN {
                let y = min(h - 1, gy * h / gridN)
                for gx in 0..<gridN {
                    let x = min(w - 1, gx * w / gridN)
                    let p = base + y * bpr + x * 4
                    // BGRA → Rec.601 luma, normalized.
                    let luma = 0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])
                    out[gy * gridN + gx] = luma / 255
                }
            }
            return out
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self)
            else { return [] }
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let pw = CVPixelBufferGetWidthOfPlane(buffer, 0), ph = CVPixelBufferGetHeightOfPlane(buffer, 0)
            for gy in 0..<gridN {
                let y = min(ph - 1, gy * ph / gridN)
                for gx in 0..<gridN {
                    let x = min(pw - 1, gx * pw / gridN)
                    out[gy * gridN + gx] = Float(base[y * bpr + x]) / 255
                }
            }
            return out
        default:
            return []
        }
    }
}
